import Foundation
import GRDB

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

extension UsageStore {
    /// 明确重算才覆盖已有价格与金额；扫描事实和历史 token 保持不变。
    public func repriceUsage() throws -> RepriceReport {
        try FileWriteLock(url: databaseURL.appendingPathExtension("write.lock")).withLock {
            var report = RepriceReport()
            var lastID: Int64 = 0
            while true {
                let count = try autoreleasepool { try pool.write { db -> Int in
                    let rows = try Row.fetchAll(db, sql: "SELECT * FROM usage WHERE id > ? ORDER BY id LIMIT 512", arguments: [lastID])
                    for row in rows {
                        let id: Int64 = row["id"]
                        lastID = id
                        let outcome = try Self.priceUsage(row, db: db)
                        report.examined += outcome.examined
                        report.changed += outcome.changed
                        report.fullyPriced += outcome.fullyPriced
                        report.partiallyPriced += outcome.partiallyPriced
                        report.unpriced += outcome.unpriced
                        report.invalidUsage += outcome.invalidUsage
                        report.overflow += outcome.overflow
                        for (reason, count) in outcome.unpricedReasons { report.unpricedReasons[reason, default: 0] += count }
                    }
                    return rows.count
                } }
                if count == 0 { break }
            }
            return report
        }
    }

    static func priceUsage(_ row: Row, db: Database) throws -> RepriceReport {
        var report = RepriceReport()
        let id: Int64 = row["id"]
        report.examined += 1
        let model: String? = row["model"]
        let date: String? = row["usage_date"]
        let price = try model.flatMap { model in try date.flatMap { try Self.modelPrice(db: db, model: model, date: $0) } }
        let input: Int64? = row["input_tokens"]
        let output: Int64? = row["output_tokens"]
        let storedFast: Bool? = row["is_fast"]
        let evidence: String = row["evidence_json"]
        let sourceTier = (try? JSONDecoder().decode(ModeEvidence.self, from: Data(evidence.utf8)))?.serviceTier
        let fast = storedFast ?? CodexServiceTier.isFast(sourceTier)
        var result: UsagePricing.Result?
        if let input, let output {
            let tokens = TokenUsage(inputTokens: input, outputTokens: output, cachedInputTokens: row["cache_read_tokens"],
                    cacheWriteInputTokens: row["cache_write_tokens"], reasoningOutputTokens: row["reasoning_tokens"],
                    totalTokens: row["total_tokens"])
            do { result = try UsagePricing.calculate(tokens: tokens, isFast: fast, price: price) }
            catch PriceError.invalidUsage { report.invalidUsage += 1 }
            catch PriceError.amountOverflow { report.overflow += 1 }
        }
        if result?.amount == nil {
            let reason: String
            if report.invalidUsage > 0 { reason = "invalid_usage" }
            else if report.overflow > 0 { reason = "amount_overflow" }
            else if model == nil { reason = "missing_model" }
            else if price == nil { reason = "no_historical_price" }
            else if fast == nil { reason = "unknown_fast_mode" }
            else if price?.contextRule == .unsupported { reason = "unsupported_context" }
            else if input == nil || output == nil || (row["cache_read_tokens"] as Int64?) == nil || (row["cache_write_tokens"] as Int64?) == nil {
                reason = "missing_usage_breakdown"
            } else { reason = "missing_component_price" }
            report.unpricedReasons[reason, default: 0] += 1
        }
        if result?.amount != nil { report.fullyPriced += 1 }
        else if [result?.inputAmount, result?.outputAmount, result?.cacheReadAmount, result?.cacheWriteAmount]
            .contains(where: { ($0 ?? 0) > 0 }) { report.partiallyPriced += 1 }
        else { report.unpriced += 1 }
        let columns = ["is_fast", "is_long_context", "input_price", "output_price", "cache_read_price", "cache_write_price",
                       "input_amount", "output_amount", "cache_read_amount", "cache_write_amount", "amount"]
        let values: [(any DatabaseValueConvertible)?] = [
            fast, result?.isLongContext,
            result?.rates.input.map { NSDecimalNumber(decimal: $0).stringValue },
            result?.rates.output.map { NSDecimalNumber(decimal: $0).stringValue },
            result?.rates.cacheRead.map { NSDecimalNumber(decimal: $0).stringValue },
            result?.rates.cacheWrite.map { NSDecimalNumber(decimal: $0).stringValue },
            result?.inputAmount, result?.outputAmount, result?.cacheReadAmount, result?.cacheWriteAmount, result?.amount
        ]
        let assignments = columns.map { "\($0) = ?" }.joined(separator: ", ")
        let unchanged = columns.map { "\($0) IS ?" }.joined(separator: " AND ")
        try db.execute(sql: "UPDATE usage SET \(assignments) WHERE id = ? AND NOT (\(unchanged))",
                       arguments: StatementArguments(values + [id] + values))
        report.changed += db.changesCount
        return report
    }
    private struct ModeEvidence: Decodable { let serviceTier: String? }

}
