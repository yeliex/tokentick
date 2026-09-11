import Foundation
import GRDB
import CryptoKit

public struct RepriceReport: Codable, Sendable {
    public var examined = 0
    public var changed = 0
    public var fullyPriced = 0
    public var partiallyPriced = 0
    public var unpriced = 0
    public var invalidUsage = 0
    public var overflow = 0
    public var unpricedReasons: [String: Int] = [:]
}

private struct RepriceCheckpoint: Codable {
    // 计价算法或断点格式变化时递增，避免恢复时混合新旧计算结果。
    static let currentVersion = 4
    static let key = "reprice_checkpoint"
    let version: Int
    let fromDate: String?
    let priceFingerprint: String
    var revision: Int64
    var lastID: Int64 = 0
    var report = RepriceReport()

    static func priceFingerprint(_ db: Database) throws -> String {
        var columns = ["model", "date", "tier", "long_context_threshold", "source_json"]
        for prefix in ["", "long_"] {
            for component in ["input", "output", "cache_read", "cache_write"] {
                columns.append(prefix + component + "_price")
            }
        }
        let rows = try String.fetchCursor(db, sql: "SELECT json_array(\(columns.joined(separator: ","))) FROM prices ORDER BY model, tier, date")
        var hash = SHA256()
        hash.update(data: try BundledModelPrices.data.get())
        while let row = try rows.next() { hash.update(data: Data(row.utf8)) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

extension UsageStore {
    func needsRepricing() throws -> Bool {
        try pool.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM app_metadata WHERE key = 'pricing_algorithm'") != "4"
                || String.fetchOne(db, sql: "SELECT value FROM app_metadata WHERE key = 'pricing_rebuild_pending'") == "true"
                || String.fetchOne(db, sql: "SELECT value FROM app_metadata WHERE key = 'pricing_defaults_hash'") != BundledModelPrices.fingerprint()
        }
    }
    /// 明确重算才覆盖已有价格与金额；相同依据的中断任务从已提交批次恢复，报告包含此前批次。
    public func repriceUsage(fromDate: String? = nil) throws -> RepriceReport {
        try UsageQuery(fromDate: fromDate).validate()
        return try FileWriteLock(url: databaseURL.appendingPathExtension("write.lock")).withLock {
            var checkpoint = try pool.read { db in
                let revision = try Self.statisticsRevision(db)
                let fingerprint = try RepriceCheckpoint.priceFingerprint(db)
                if let json = try String.fetchOne(db, sql: "SELECT value FROM app_metadata WHERE key = ?", arguments: [RepriceCheckpoint.key]),
                   let saved = try? JSONDecoder().decode(RepriceCheckpoint.self, from: Data(json.utf8)),
                   saved.version == RepriceCheckpoint.currentVersion, saved.fromDate == fromDate,
                   saved.revision == revision, saved.priceFingerprint == fingerprint {
                    return saved
                }
                return RepriceCheckpoint(version: RepriceCheckpoint.currentVersion, fromDate: fromDate,
                                         priceFingerprint: fingerprint, revision: revision)
            }
            while true {
                try Task.checkCancellation()
                let count = try autoreleasepool { try pool.write { db -> Int in
                    let rows = try Row.fetchAll(db, sql: "SELECT * FROM usage WHERE id > ? AND (? IS NULL OR usage_date >= ?) ORDER BY id LIMIT 512",
                                               arguments: [checkpoint.lastID, fromDate, fromDate])
                    if rows.isEmpty {
                        try db.execute(sql: "DELETE FROM app_metadata WHERE key = ?", arguments: [RepriceCheckpoint.key])
                        if fromDate == nil {
                            try db.execute(sql: "INSERT INTO app_metadata(key, value) VALUES ('pricing_algorithm', '4') ON CONFLICT(key) DO UPDATE SET value = '4'")
                            try db.execute(sql: "DELETE FROM app_metadata WHERE key = 'pricing_rebuild_pending'")
                            try db.execute(sql: "INSERT INTO app_metadata(key,value) VALUES ('pricing_defaults_hash',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", arguments: [try BundledModelPrices.fingerprint()])
                        }
                        return 0
                    }
                    for row in rows {
                        let id: Int64 = row["id"]
                        checkpoint.lastID = id
                        let outcome = try Self.priceUsage(row, db: db)
                        checkpoint.report.examined += outcome.examined
                        checkpoint.report.changed += outcome.changed
                        checkpoint.report.fullyPriced += outcome.fullyPriced
                        checkpoint.report.partiallyPriced += outcome.partiallyPriced
                        checkpoint.report.unpriced += outcome.unpriced
                        checkpoint.report.invalidUsage += outcome.invalidUsage
                        checkpoint.report.overflow += outcome.overflow
                        for (reason, count) in outcome.unpricedReasons { checkpoint.report.unpricedReasons[reason, default: 0] += count }
                    }
                    // 自身计价也会推进事实版本；与结果同事务保存，其他写入会使断点失效。
                    checkpoint.revision = try Self.statisticsRevision(db)
                    let json = String(decoding: try JSONEncoder().encode(checkpoint), as: UTF8.self)
                    try db.execute(sql: "INSERT INTO app_metadata(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                                   arguments: [RepriceCheckpoint.key, json])
                    return rows.count
                } }
                if count == 0 { break }
            }
            return checkpoint.report
        }
    }

    static func priceUsage(_ row: Row, db: Database) throws -> RepriceReport {
        var report = RepriceReport()
        let id: Int64 = row["id"]
        report.examined += 1
        let model: String? = row["model"]
        let input: Int64? = row["input_tokens"]
        let output: Int64? = row["output_tokens"]
        let context = try pricingContext(row, db: db)
        let price = context.price
        var result: UsagePricing.Result?
        if let input, let output {
            let tokens = TokenUsage(inputTokens: input, outputTokens: output, cachedInputTokens: row["cache_read_tokens"],
                    cacheWriteInputTokens: row["cache_write_tokens"], reasoningOutputTokens: row["reasoning_tokens"],
                    totalTokens: row["total_tokens"])
            do { result = try UsagePricing.calculate(tokens: tokens, price: price) }
            catch PriceError.invalidUsage { report.invalidUsage += 1 }
            catch PriceError.amountOverflow { report.overflow += 1 }
        }
        if result?.amount == nil {
            let reason: String
            if report.invalidUsage > 0 { reason = "invalid_usage" }
            else if report.overflow > 0 { reason = "amount_overflow" }
            else if model == nil { reason = "missing_model" }
            else if price == nil { reason = "no_historical_price" }
            else if price?.contextRule == .unsupported { reason = "unsupported_context" }
            else if input == nil || output == nil || (row["cache_read_tokens"] as Int64?) == nil || (row["cache_write_tokens"] as Int64?) == nil {
                reason = "missing_usage_breakdown"
            } else { reason = "missing_component_price" }
            report.unpricedReasons[reason] = 1
        }
        if result?.amount != nil { report.fullyPriced += 1 }
        else if [result?.inputAmount, result?.outputAmount, result?.cacheReadAmount, result?.cacheWriteAmount]
            .contains(where: { ($0 ?? 0) > 0 }) { report.partiallyPriced += 1 }
        else { report.unpriced += 1 }
        let columns = ["evidence_json", "tier", "is_long_context", "input_price", "output_price", "cache_read_price", "cache_write_price",
                       "input_amount", "output_amount", "cache_read_amount", "cache_write_amount", "amount"]
        let values: [(any DatabaseValueConvertible)?] = [
            context.evidenceJSON, context.observedTier, result?.isLongContext,
            result?.rates.input.map { NSDecimalNumber(decimal: $0).stringValue },
            result?.rates.output.map { NSDecimalNumber(decimal: $0).stringValue },
            result?.rates.cacheRead.map { NSDecimalNumber(decimal: $0).stringValue },
            result?.rates.cacheWrite.map { NSDecimalNumber(decimal: $0).stringValue },
            result?.inputAmount, result?.outputAmount, result?.cacheReadAmount, result?.cacheWriteAmount, result?.amount
        ]
        let assignments = columns.map { "\($0) = ?" }.joined(separator: ", ")
        let unchanged = columns.map { "\($0) IS ?" }.joined(separator: " AND ")
        let update = try db.cachedStatement(sql: "UPDATE usage SET \(assignments) WHERE id = ? AND NOT (\(unchanged))")
        try update.execute(arguments: StatementArguments(values + [id] + values))
        report.changed += db.changesCount
        return report
    }

    private static func pricingContext(_ row: Row, db: Database) throws
        -> (price: ModelPrice?, observedTier: String?, evidenceJSON: String) {
        let model: String? = row["model"]
        let date: String? = row["usage_date"]
        let storedTier: String? = row["tier"]
        let evidence: String = row["evidence_json"]
        let sourceTier = (try? JSONDecoder().decode(ModeEvidence.self, from: Data(evidence.utf8)))?.serviceTier
        let observedTier = storedTier ?? CodexServiceTier.normalized(sourceTier)
        let thread: String? = row["thread_id"]
        let turn: String? = row["turn_id"]
        let trace = try observedTier == nil ? thread.flatMap { thread in
            try turn.flatMap { turn in
                try String.fetchOne(db, sql: "SELECT value FROM app_metadata WHERE key=?", arguments: ["fast_trace:\(thread):\(turn)"])
            }
        } : nil
        let selectedTier = observedTier ?? (trace == nil ? "standard" : "fast")
        let fast = selectedTier == "fast"
        let price = try model.flatMap { model in try date.flatMap { try Self.modelPrice(db: db, model: model, date: $0, tier: selectedTier) } }
        var proof = (try? JSONSerialization.jsonObject(with: Data(evidence.utf8))) as? [String: Any] ?? [:]
        var mode: [String: Any] = ["isFast": fast, "tier": selectedTier, "source": observedTier != nil ? "rollout" : (trace != nil ? "trace" : "default_standard")]
        if let trace { mode["trace"] = try JSONSerialization.jsonObject(with: Data(trace.utf8)) }
        proof["pricingMode"] = mode
        if let price { proof["pricingPrice"] = ["model": price.model, "date": price.date, "tier": price.tier, "url": price.source.url, "bundled": price.source.isBundled == true] }
        else { proof.removeValue(forKey: "pricingPrice") }
        let updatedEvidence = String(decoding: try JSONSerialization.data(withJSONObject: proof, options: [.sortedKeys]), as: UTF8.self)
        return (price, observedTier, updatedEvidence)
    }

    private struct ModeEvidence: Decodable { let serviceTier: String? }

}
