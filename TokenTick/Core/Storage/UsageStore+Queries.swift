import Foundation
import GRDB

public enum UsageGrouping: String, CaseIterable, Codable, Sendable {
    case total, day, thread, project, model
}

public struct UsageSummary: Codable, Sendable, Equatable {
    public let group: String?
    public let records: Int
    public let totalTokens: Int64
    public let inputTokens: Int64?
    public let outputTokens: Int64?
    public let cachedInputTokens: Int64?
    public let cacheWriteInputTokens: Int64?
    public let reasoningOutputTokens: Int64?
    public let knownAmountNanoUSD: Int64?
    public let inputAmountNanoUSD: Int64?
    public let outputAmountNanoUSD: Int64?
    public let cacheReadAmountNanoUSD: Int64?
    public let cacheWriteAmountNanoUSD: Int64?
    public let completeAmountNanoUSD: Int64?
    public let unpricedTokens: Int64
    public let unpricedRecords: Int
    public let unattributedTokens: Int64

    private enum CodingKeys: String, CodingKey {
        case group, records, totalTokens, inputTokens, outputTokens, cachedInputTokens
        case cacheWriteInputTokens, reasoningOutputTokens, knownAmountNanoUSD, unpricedTokens
        case inputAmountNanoUSD, outputAmountNanoUSD, cacheReadAmountNanoUSD, cacheWriteAmountNanoUSD
        case completeAmountNanoUSD, unpricedRecords, unattributedTokens
    }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(group, forKey: .group)
        try values.encode(records, forKey: .records)
        try values.encode(totalTokens, forKey: .totalTokens)
        try values.encode(inputTokens, forKey: .inputTokens)
        try values.encode(outputTokens, forKey: .outputTokens)
        try values.encode(cachedInputTokens, forKey: .cachedInputTokens)
        try values.encode(cacheWriteInputTokens, forKey: .cacheWriteInputTokens)
        try values.encode(reasoningOutputTokens, forKey: .reasoningOutputTokens)
        try values.encode(knownAmountNanoUSD, forKey: .knownAmountNanoUSD)
        try values.encode(inputAmountNanoUSD, forKey: .inputAmountNanoUSD)
        try values.encode(outputAmountNanoUSD, forKey: .outputAmountNanoUSD)
        try values.encode(cacheReadAmountNanoUSD, forKey: .cacheReadAmountNanoUSD)
        try values.encode(cacheWriteAmountNanoUSD, forKey: .cacheWriteAmountNanoUSD)
        try values.encode(completeAmountNanoUSD, forKey: .completeAmountNanoUSD)
        try values.encode(unpricedTokens, forKey: .unpricedTokens)
        try values.encode(unpricedRecords, forKey: .unpricedRecords)
        try values.encode(unattributedTokens, forKey: .unattributedTokens)
    }
}

extension UsageStore {
    public func usageSummaries(grouping: UsageGrouping = .day, limit: Int = 100) throws -> [UsageSummary] {
        try usageReport(UsageQuery(grouping: grouping, limit: limit)).rows
    }

    /// 只返回分页统计。缓存与事实版本不一致时重建，不把历史请求全集交给调用者。
    public func usageReport(_ query: UsageQuery = UsageQuery()) throws -> UsageReport {
        try query.validate()
        let identifier = try query.timezone ?? statisticsTimezone()
        guard let timezone = TimeZone(identifier: identifier) else { throw UsageQueryError.invalidTimezone }
        if try query.filters.isEmpty && !pool.read({ try Self.statisticsAreCurrent($0, timezone: timezone.identifier) }) {
            do { _ = try rebuildStatistics(timezone: timezone, onlyIfNeeded: true) }
            catch FileWriteLock.LockError.busy {
                // 扫描者持有跨进程锁时，直接查询已提交事实，界面不等待整次扫描结束。
            }
        }
        return try pool.read { try Self.readUsageReport(query, timezone: timezone, db: $0) }
    }

    static func readUsageReport(_ query: UsageQuery, timezone: TimeZone, db: Database) throws -> UsageReport {
        // 重建与读取之间另一个进程可能提交了用量；同一读快照内回退到事实聚合。
        let current = try query.filters.isEmpty && Self.statisticsAreCurrent(db, timezone: timezone.identifier)
        if !current { StatisticsSQL.prepare(db, timezone: timezone) }
        let factFilters = UsageFiltersSQL(query.filters)
        let source = current ? "" : "WITH statistics(\(StatisticsSQL.columns)) AS (\(StatisticsSQL.aggregate(predicate: factFilters.predicate))) "
        let dimension = [.total, .day].contains(query.grouping) ? "all" : query.grouping.rawValue
        let group = switch query.grouping {
        case .total: "NULL"
        case .day: "CASE WHEN date = 'unknown' THEN NULL ELSE date END"
        default: "CASE WHEN dimension_value = 'unknown' THEN NULL ELSE substr(dimension_value, 7) END"
        }
        var arguments: StatementArguments = ["timezone": timezone.identifier, "account": query.account.key,
                                             "dimension": dimension, "limit": query.limit + 1, "offset": query.offset]
        arguments += factFilters.arguments
        var filters = "timezone = :timezone AND account_key = :account AND dimension = :dimension"
        if let from = query.fromDate {
            filters += " AND date != 'unknown' AND date >= :from"
            arguments += ["from": from]
        }
        if let through = query.throughDate {
            filters += " AND date != 'unknown' AND date <= :through"
            arguments += ["through": through]
        }
        let order: String
        switch query.sort {
        case .automatic: order = query.grouping == .day ? "group_value IS NULL, group_value DESC" : "total_tokens DESC, group_value ASC"
        case .tokens: order = "total_tokens DESC, group_value ASC"
        case .amount: order = "known_amount IS NULL, known_amount DESC, group_value ASC"
        case .name:
            order = query.grouping == .thread
                ? "COALESCE((SELECT title FROM threads WHERE thread_id = group_value), group_value) COLLATE NOCASE ASC, group_value ASC"
                : "group_value ASC"
        }
        let rows = try Row.fetchAll(db, sql: """
            \(source)SELECT \(group) AS group_value, SUM(record_count) AS records,
                SUM(total_tokens) AS total_tokens, SUM(input_tokens) AS input_tokens,
                SUM(output_tokens) AS output_tokens, SUM(cache_read_tokens) AS cache_read_tokens,
                SUM(cache_write_tokens) AS cache_write_tokens, SUM(reasoning_tokens) AS reasoning_tokens,
                SUM(known_amount) AS known_amount, SUM(input_amount) AS input_amount,
                SUM(output_amount) AS output_amount, SUM(cache_read_amount) AS cache_read_amount,
                SUM(cache_write_amount) AS cache_write_amount, SUM(complete_amount) AS complete_amount,
                SUM(unpriced_tokens) AS unpriced_tokens, SUM(unpriced_records) AS unpriced_records,
                SUM(unattributed_tokens) AS unattributed_tokens
            FROM statistics WHERE \(filters) GROUP BY group_value
            ORDER BY \(order)
            LIMIT :limit OFFSET :offset
            """, arguments: arguments)
        let unknown = try Int64.fetchOne(db, sql: """
            \(source)SELECT SUM(total_tokens) FROM statistics
            WHERE timezone = :timezone AND account_key = :account AND dimension = 'all' AND date = 'unknown'
            """, arguments: ["timezone": timezone.identifier, "account": query.account.key] + factFilters.arguments) ?? 0
        let summaries = rows.prefix(query.limit).map { row in
            UsageSummary(group: row["group_value"], records: row["records"], totalTokens: row["total_tokens"],
                         inputTokens: row["input_tokens"], outputTokens: row["output_tokens"],
                         cachedInputTokens: row["cache_read_tokens"], cacheWriteInputTokens: row["cache_write_tokens"],
                         reasoningOutputTokens: row["reasoning_tokens"], knownAmountNanoUSD: row["known_amount"],
                         inputAmountNanoUSD: row["input_amount"], outputAmountNanoUSD: row["output_amount"],
                         cacheReadAmountNanoUSD: row["cache_read_amount"], cacheWriteAmountNanoUSD: row["cache_write_amount"],
                         completeAmountNanoUSD: row["complete_amount"], unpricedTokens: row["unpriced_tokens"],
                         unpricedRecords: row["unpriced_records"], unattributedTokens: row["unattributed_tokens"])
        }
        return UsageReport(timezone: timezone.identifier, grouping: query.grouping, fromDate: query.fromDate,
                           throughDate: query.throughDate, unknownDateTokens: unknown, rows: summaries, hasMore: rows.count > query.limit)
    }
}
