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
    // Increment when pricing or checkpoint formats change to prevent mixing results across versions.
    static let currentVersion = 9
    static let key = "reprice_checkpoint"
    let version: Int
    let fromDate: String?
    let onlyMissing: Bool?
    let priceFingerprint: String
    var revision: Int64
    var lastID: Int64 = 0
    var report = RepriceReport()

    static func priceFingerprint(_ db: Database) throws -> String {
        var columns = ["model", "date", "tier", "effective_at", "long_context_threshold", "context_rule", "combination_rule"]
        for prefix in ["", "long_"] {
            for component in ["input", "output", "cache_read", "cache_write"] {
                columns.append(prefix + component + "_price")
            }
        }
        let rows = try String.fetchCursor(db, sql: "SELECT json_array(\(columns.joined(separator: ","))) FROM prices ORDER BY model, tier, effective_at")
        var hash = SHA256()
        hash.update(data: try BundledModelPrices.data.get())
        while let row = try rows.next() { hash.update(data: Data(row.utf8)) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

extension UsageStore {
    func needsRepricing() throws -> Bool {
        try pool.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM app_metadata WHERE key = 'pricing_algorithm'") != String(RepriceCheckpoint.currentVersion)
                || String.fetchOne(db, sql: "SELECT value FROM app_metadata WHERE key = 'pricing_rebuild_pending'") == "true"
                || String.fetchOne(db, sql: "SELECT value FROM app_metadata WHERE key = 'pricing_defaults_hash'") != BundledModelPrices.fingerprint()
        }
    }
    /// Only repricing replaces applied costs; resume matching interrupted work from committed batches and include prior progress.
    public func repriceUsage(fromDate: String? = nil) throws -> RepriceReport {
        try repriceUsage(fromDate: fromDate, onlyMissing: false)
    }

    func repriceUsage(fromDate: String? = nil, onlyMissing: Bool) throws -> RepriceReport {
        try UsageQuery(fromDate: fromDate).validate()
        return try FileWriteLock(url: databaseURL.appendingPathExtension("write.lock")).withLock {
            var checkpoint = try pool.read { db in
                let revision = try Self.statisticsRevision(db)
                let fingerprint = try RepriceCheckpoint.priceFingerprint(db)
                if let json = try String.fetchOne(db, sql: "SELECT value FROM app_metadata WHERE key = ?", arguments: [RepriceCheckpoint.key]),
                   let saved = try? JSONDecoder().decode(RepriceCheckpoint.self, from: Data(json.utf8)),
                   saved.version == RepriceCheckpoint.currentVersion, saved.fromDate == fromDate,
                   (saved.onlyMissing ?? false) == onlyMissing,
                   saved.revision == revision, saved.priceFingerprint == fingerprint {
                    return saved
                }
                return RepriceCheckpoint(version: RepriceCheckpoint.currentVersion, fromDate: fromDate, onlyMissing: onlyMissing,
                                         priceFingerprint: fingerprint, revision: revision)
            }
            while true {
                try Task.checkCancellation()
                let count = try autoreleasepool { try pool.write { db -> Int in
                    let rows = try Row.fetchAll(db, sql: """
                        SELECT * FROM usage WHERE id > ? AND (? IS NULL OR usage_date >= ?)
                            AND (NOT ? OR amount IS NULL OR api_amount IS NULL) ORDER BY id LIMIT 512
                        """, arguments: [checkpoint.lastID, fromDate, fromDate, onlyMissing])
                    if rows.isEmpty {
                        try db.execute(sql: "DELETE FROM app_metadata WHERE key = ?", arguments: [RepriceCheckpoint.key])
                        if fromDate == nil {
                            try db.execute(sql: "INSERT INTO app_metadata(key, value) VALUES ('pricing_algorithm', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                                           arguments: [String(RepriceCheckpoint.currentVersion)])
                            try db.execute(sql: "DELETE FROM app_metadata WHERE key = 'pricing_rebuild_pending'")
                            try db.execute(sql: "INSERT INTO app_metadata(key,value) VALUES ('pricing_defaults_hash',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", arguments: [try BundledModelPrices.fingerprint()])
                        }
                        return 0
                    }
                    for row in rows {
                        let id: Int64 = row["id"]
                        checkpoint.lastID = id
                        let outcome = try Self.priceUsage(row, db: db, onlyMissing: onlyMissing)
                        checkpoint.report.examined += outcome.examined
                        checkpoint.report.changed += outcome.changed
                        checkpoint.report.fullyPriced += outcome.fullyPriced
                        checkpoint.report.partiallyPriced += outcome.partiallyPriced
                        checkpoint.report.unpriced += outcome.unpriced
                        checkpoint.report.invalidUsage += outcome.invalidUsage
                        checkpoint.report.overflow += outcome.overflow
                        for (reason, count) in outcome.unpricedReasons { checkpoint.report.unpricedReasons[reason, default: 0] += count }
                    }
                    // Repricing also advances fact revisions; save checkpoints with results so other writes invalidate them.
                    checkpoint.revision = try Self.statisticsRevision(db)
                    let json = String(decoding: try JSONEncoder().encode(checkpoint), as: UTF8.self)
                    try db.execute(sql: "INSERT INTO app_metadata(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                                   arguments: [RepriceCheckpoint.key, json])
                    return rows.count
                } }
                if count == 0 { break }
            }
            try pool.write { try Self.refreshWeeklyCycleUsage($0) }
            return checkpoint.report
        }
    }

    static func priceUsage(_ row: Row, db: Database, onlyMissing: Bool = false,
                           preservingPricingFrom previous: Row? = nil) throws -> RepriceReport {
        var report = RepriceReport()
        let id: Int64 = row["id"]
        report.examined += 1
        let model: String? = row["model"]
        let input: Int64? = row["input_tokens"]
        let output: Int64? = row["output_tokens"]
        let context = try pricingContext(row, db: db)
        // Replaying a request can enrich its metadata without changing the basis of its saved price.
        let samePricingBasis = previous.map { old in
            (old["model"] as String?) == model
                && (old["billing_mode"] as String) == (row["billing_mode"] as String)
                && (old["occurred_at"] as Double?) == (row["occurred_at"] as Double?)
                && ((old["pricing_tier"] as String?) ?? (old["tier"] as String?) ?? "standard") == context.selectedTier
        } ?? false
        if samePricingBasis, (row["amount"] as Int64?) != nil, (row["api_amount"] as Int64?) != nil {
            // Record stronger evidence for the same tier without substituting rates or changing amounts.
            try db.execute(sql: "UPDATE usage SET pricing_source=? WHERE id=? AND pricing_source IS NOT ?",
                           arguments: [context.source, id, context.source])
            report.fullyPriced = 1
            report.changed = db.changesCount
            return report
        }
        let price = context.price
        var result: UsagePricing.Result?
        var api: UsagePricing.Result?
        if let input, let output {
            let tokens = TokenUsage(inputTokens: input, outputTokens: output, cachedInputTokens: row["cache_read_tokens"],
                    cacheWriteInputTokens: row["cache_write_tokens"], reasoningOutputTokens: row["reasoning_tokens"],
                    totalTokens: row["total_tokens"])
            do { api = try UsagePricing.calculate(tokens: tokens, price: price) }
            catch PriceError.invalidUsage { report.invalidUsage = 1 }
            catch PriceError.amountOverflow { report.overflow = 1 }
            do {
                if row["billing_mode"] as String == "plan", api?.isLongContext != false {
                    result = try UsagePricing.calculate(tokens: tokens, price: price, applyLongContextRates: false)
                } else { result = api }
            } catch PriceError.invalidUsage { report.invalidUsage = 1 }
            catch PriceError.amountOverflow { report.overflow = 1 }
        }
        let columns = ["pricing_tier", "pricing_source", "price_date", "tier", "is_long_context", "input_price", "output_price", "cache_read_price", "cache_write_price",
                       "input_amount", "output_amount", "cache_read_amount", "cache_write_amount", "amount",
                       "api_input_amount", "api_output_amount", "api_cache_read_amount", "api_cache_write_amount", "api_amount", "api_is_long_context"]
        let calculated: [(any DatabaseValueConvertible)?] = [
            context.selectedTier, context.source, price?.date, context.observedTier, result?.isLongContext,
            result?.rates.input.map { NSDecimalNumber(decimal: $0).stringValue },
            result?.rates.output.map { NSDecimalNumber(decimal: $0).stringValue },
            result?.rates.cacheRead.map { NSDecimalNumber(decimal: $0).stringValue },
            result?.rates.cacheWrite.map { NSDecimalNumber(decimal: $0).stringValue },
            result?.inputAmount, result?.outputAmount, result?.cacheReadAmount, result?.cacheWriteAmount, result?.amount,
            api?.inputAmount, api?.outputAmount, api?.cacheReadAmount, api?.cacheWriteAmount, api?.amount, api?.isLongContext
        ]
        var values = calculated.map { $0?.databaseValue ?? .null }
        let componentColumns = ["input_amount", "output_amount", "cache_read_amount", "cache_write_amount"]
        func writtenAmount(_ column: String) -> Int64? {
            columns.firstIndex(of: column).flatMap { Int64.fromDatabaseValue(values[$0]) }
        }
        if onlyMissing || samePricingBasis {
            // Historical amounts already shown to the user remain fixed when a new catalog fills gaps.
            for (index, column) in columns.enumerated() {
                let existing: DatabaseValue = row[column]
                if !existing.isNull { values[index] = existing }
            }
            for prefix in ["", "api_"] {
                guard let index = columns.firstIndex(of: prefix + "amount"),
                      (row[prefix + "amount"] as Int64?) == nil else { continue }
                let sum = try UsagePricing.total(componentColumns.map { writtenAmount(prefix + $0) })
                values[index] = sum?.databaseValue ?? .null
            }
        }
        if writtenAmount("amount") != nil { report.fullyPriced = 1 }
        else {
            if componentColumns.contains(where: { (writtenAmount($0) ?? 0) > 0 }) { report.partiallyPriced = 1 }
            else { report.unpriced = 1 }
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
        let assignments = columns.map { "\($0) = ?" }.joined(separator: ", ")
        let unchanged = columns.map { "\($0) IS ?" }.joined(separator: " AND ")
        let update = try db.cachedStatement(sql: "UPDATE usage SET \(assignments) WHERE id = ? AND NOT (\(unchanged))")
        try update.execute(arguments: StatementArguments(values + [id] + values))
        report.changed += db.changesCount
        return report
    }

    private static func pricingContext(_ row: Row, db: Database) throws
        -> (price: ModelPrice?, observedTier: String?, selectedTier: String, source: String) {
        let model: String? = row["model"], date: String? = row["usage_date"], observedTier: String? = row["tier"]
        let evidence = try traceTier(row, db: db)
        let selectedTier = evidence?.tier ?? observedTier ?? "standard"
        let occurredAt: Double? = row["occurred_at"]
        let price = try model.flatMap { model in try date.flatMap { try Self.modelPrice(db: db, model: model, date: $0,
                                                                                       tier: selectedTier, occurredAt: occurredAt) } }
        return (price, observedTier, selectedTier, evidence?.source ?? (observedTier != nil ? "rollout" : "default_standard"))
    }

    private static func traceTier(_ row: Row, db: Database) throws -> (tier: String, source: String)? {
        guard let device: String = row["device"], let thread: String = row["thread_id"],
              let turn: String = row["turn_id"] else { return nil }
        let prefix = "tier_trace:\(device):\(thread):\(turn):"
        if let response: String = row["response_id"],
           let exact = try String.fetchOne(db, sql: "SELECT value FROM app_metadata WHERE key=?", arguments: [prefix + response]),
           exact.count > 2 {
            return (String(exact.dropFirst(2)), exact.hasPrefix("3:") ? "response_trace" : "request_trace")
        }
        let observed: String? = row["tier"]
        guard observed == nil else { return nil }
        if let turnEvidence = try String.fetchOne(db, sql: "SELECT value FROM app_metadata WHERE key=?", arguments: [prefix]) {
            // A request without a response identifier cannot distinguish multiple billed responses.
            guard turnEvidence.count > 2,
                  try Int.fetchOne(db, sql: """
                      SELECT COUNT(*) FROM (SELECT 1 FROM usage WHERE thread_id=? AND turn_id=? AND device=? LIMIT 2)
                      """, arguments: [thread, turn, device]) == 1 else { return nil }
            return (String(turnEvidence.dropFirst(2)), "turn_trace")
        }
        let previousSource: String? = row["pricing_source"]
        if previousSource == "trace", try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM app_metadata WHERE key=?)",
                                                        arguments: ["fast_trace:\(thread):\(turn)"]) == true {
            return ("fast", "trace")
        }
        return nil
    }
}
