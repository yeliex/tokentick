import Foundation
import GRDB

public enum OverviewPeriod: String, CaseIterable, Sendable, Identifiable {
    case day = "1 天", week = "7 天", month = "30 天", quarter = "90 天", year = "一年", all = "历史总和"
    public var id: Self { self }
    public var days: Int? {
        switch self { case .day: 1; case .week: 7; case .month: 30; case .quarter: 90; case .year: 365; case .all: nil }
    }
    public func query(now: Date, timezone: String) -> UsageQuery {
        var query = UsageQuery(grouping: .total, timezone: timezone)
        if let days {
            query.filters.occurredFrom = now.timeIntervalSince1970 - Double(days) * 86400
            query.filters.occurredBefore = now.timeIntervalSince1970
        }
        return query
    }
}

public struct OverviewTrendPoint: Sendable, Identifiable, Equatable {
    public var id: Date { date }
    public let date: Date
    public let summary: UsageSummary
}

public struct OverviewConversation: Sendable, Identifiable, Equatable {
    public var id: String { thread.id }
    public let thread: ThreadInfo
    public let summary: UsageSummary
}

public struct OverviewUsageShare: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let tokens: Int64
    public let amount: Int64?
    public init(name: String, tokens: Int64, amount: Int64?) {
        self.name = name; self.tokens = tokens; self.amount = amount
    }
}

public struct OverviewReport: Sendable {
    public let query: UsageQuery
    public let total: UsageSummary?
    public let models: [UsageSummary]
    public let modes: [OverviewUsageShare]
    public let efforts: [OverviewUsageShare]
    public let trend: [OverviewTrendPoint]
    public let conversations: [OverviewConversation]
    public let unknownDateTokens: Int64
    public let hourly: Bool

    /// 滚动查询的截止时间变化不代表显示数据变化。
    public func hasSameContent(as other: Self) -> Bool {
        total == other.total && models == other.models && modes == other.modes && efforts == other.efforts && trend == other.trend
            && conversations == other.conversations && unknownDateTokens == other.unknownDateTokens
            && hourly == other.hourly && query.timezone == other.query.timezone
    }
}

extension UsageStore {
    /// 一个读快照内取得首页所有区块，避免同步写入使金额、图表与模型构成互相矛盾。
    public func overviewReport(period: OverviewPeriod, now: Date, timezone identifier: String) throws -> OverviewReport {
        guard let timezone = TimeZone(identifier: identifier) else { throw UsageQueryError.invalidTimezone }
        let query = period.query(now: now, timezone: identifier)
        try query.validate()
        return try pool.read { db in
            StatisticsSQL.prepare(db, timezone: timezone)
            let total = try Self.readUsageReport(query, timezone: timezone, db: db)
            var grouped = query
            grouped.grouping = .model; grouped.limit = 10_000; grouped.sort = .tokens
            let models = try Self.readUsageReport(grouped, timezone: timezone, db: db).rows
            grouped.grouping = .day; grouped.sort = .automatic
            let day = StatisticsSQL.dayExpression
            let expression: String? = period == .all
                ? "CASE WHEN (\(day)) = 'unknown' THEN 'unknown' ELSE substr((\(day)), 1, 7) || '-01' END"
                : period == .year ? "CASE WHEN (\(day)) = 'unknown' THEN 'unknown' ELSE date((\(day)), '-6 days', 'weekday 1') END" : nil
            let chart = try Self.readUsageReport(grouped, timezone: timezone, db: db, dateExpression: expression)
            let style = Date.ISO8601FormatStyle(timeZone: timezone).year().month().day().dateSeparator(.dash)
            let trend = chart.rows.compactMap { row -> OverviewTrendPoint? in
                guard let group = row.group else { return nil }
                let date = try? style.parse(group)
                return date.map { OverviewTrendPoint(date: $0, summary: row) }
            }.sorted { $0.date < $1.date }
            let filters = UsageFiltersSQL(query.filters)
            let modeExpression = """
                CASE WHEN u.is_long_context IS NULL THEN '未知'
                    WHEN json_extract(u.evidence_json, '$.pricingMode.isFast') = 1 OR u.tier = 'fast'
                        THEN CASE WHEN u.is_long_context = 1 THEN '快速＋长上下文' ELSE '快速' END
                    WHEN u.is_long_context = 1 THEN '长上下文' ELSE '普通' END
                """
            let effortExpression = "COALESCE(NULLIF(json_extract(u.evidence_json, '$.reasoningEffort'), ''), '未知')"
            func shares(_ expression: String) throws -> [OverviewUsageShare] {
                try Row.fetchAll(db, sql: """
                    SELECT \(expression) AS name, SUM(u.total_tokens) AS tokens,
                        SUM(tokentick_known_amount(u.input_amount, u.output_amount, u.cache_read_amount, u.cache_write_amount, u.amount)) AS amount
                    FROM usage u LEFT JOIN threads t ON t.thread_id = u.thread_id
                    WHERE (u.source = 'local' OR u.thread_id IS NOT NULL) AND (\(filters.predicate))
                    GROUP BY name ORDER BY tokens DESC, name ASC
                    """, arguments: filters.arguments).map { OverviewUsageShare(name: $0["name"], tokens: $0["tokens"], amount: $0["amount"]) }
            }
            let modes = try shares(modeExpression)
            let efforts = try shares(effortExpression)
            let recent = try Row.fetchAll(db, sql: """
                SELECT u.thread_id, t.title, t.project_name, MAX(u.occurred_at) AS last_active
                FROM usage u LEFT JOIN threads t ON t.thread_id = u.thread_id
                WHERE u.thread_id IS NOT NULL AND u.occurred_at IS NOT NULL AND (\(filters.predicate))
                GROUP BY u.thread_id ORDER BY last_active DESC, u.thread_id ASC LIMIT 10
                """, arguments: filters.arguments)
            let conversations = try recent.map { row in
                let id: String = row["thread_id"]
                let summary = try Self.readUsageReport(query.focused(on: .thread, value: id), timezone: timezone, db: db).rows
                return summary.first.map { OverviewConversation(thread: ThreadInfo(id: id, title: row["title"],
                    projectName: row["project_name"], lastActiveAt: row["last_active"]), summary: $0) }
            }.compactMap { $0 }
            return OverviewReport(query: query, total: total.rows.first, models: models, modes: modes, efforts: efforts, trend: trend,
                conversations: conversations, unknownDateTokens: total.unknownDateTokens, hourly: false)
        }
    }
}
