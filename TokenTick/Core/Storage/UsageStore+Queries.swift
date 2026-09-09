import Foundation
import GRDB

public enum UsageGrouping: String, CaseIterable, Sendable {
    case day, thread, project, model
}

public struct UsageSummary: Codable, Sendable {
    public let group: String?
    public let requests: Int
    public let totalTokens: Int64
    public let inputTokens: Int64?
    public let outputTokens: Int64?
    public let cachedInputTokens: Int64?
    public let cacheWriteInputTokens: Int64?
    public let reasoningOutputTokens: Int64?
    public let knownAmountNanoUSD: Int64?
    public let unpricedTokens: Int64

    private enum CodingKeys: String, CodingKey {
        case group, requests, totalTokens, inputTokens, outputTokens, cachedInputTokens
        case cacheWriteInputTokens, reasoningOutputTokens, knownAmountNanoUSD, unpricedTokens
    }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(group, forKey: .group)
        try values.encode(requests, forKey: .requests)
        try values.encode(totalTokens, forKey: .totalTokens)
        try values.encode(inputTokens, forKey: .inputTokens)
        try values.encode(outputTokens, forKey: .outputTokens)
        try values.encode(cachedInputTokens, forKey: .cachedInputTokens)
        try values.encode(cacheWriteInputTokens, forKey: .cacheWriteInputTokens)
        try values.encode(reasoningOutputTokens, forKey: .reasoningOutputTokens)
        try values.encode(knownAmountNanoUSD, forKey: .knownAmountNanoUSD)
        try values.encode(unpricedTokens, forKey: .unpricedTokens)
    }
}

extension UsageStore {
    /// 在 SQLite 内聚合，只把有界结果集交给 App 或 CLI。
    public func usageSummaries(grouping: UsageGrouping = .day, limit: Int = 100) throws -> [UsageSummary] {
        let dimension: String = switch grouping {
        case .day: "u.usage_date"
        case .thread: "u.thread_id"
        case .project: "t.project_name"
        case .model: "u.model"
        }
        return try pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT \(dimension) AS group_value, COUNT(*) AS requests,
                    SUM(u.total_tokens) AS total_tokens, SUM(u.input_tokens) AS input_tokens,
                    SUM(u.output_tokens) AS output_tokens, SUM(u.cache_read_tokens) AS cache_read_tokens,
                    SUM(u.cache_write_tokens) AS cache_write_tokens, SUM(u.reasoning_tokens) AS reasoning_tokens,
                    SUM(u.amount) AS amount,
                    SUM(CASE WHEN u.amount IS NULL THEN u.total_tokens ELSE 0 END) AS unpriced_tokens
                FROM usage u LEFT JOIN threads t ON t.thread_id = u.thread_id
                GROUP BY \(dimension)
                ORDER BY \(grouping == .day ? "group_value DESC" : "total_tokens DESC, group_value ASC")
                LIMIT ?
                """, arguments: [min(max(limit, 1), 10_000)])
            return rows.map { row in
                UsageSummary(group: row["group_value"], requests: row["requests"], totalTokens: row["total_tokens"],
                             inputTokens: row["input_tokens"], outputTokens: row["output_tokens"],
                             cachedInputTokens: row["cache_read_tokens"], cacheWriteInputTokens: row["cache_write_tokens"],
                             reasoningOutputTokens: row["reasoning_tokens"], knownAmountNanoUSD: row["amount"],
                             unpricedTokens: row["unpriced_tokens"])
            }
        }
    }
}
