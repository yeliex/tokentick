import Foundation
import GRDB

public struct LimitQuery: Sendable, Hashable {
    public var timezone: String?
    public var fromDate: String?
    public var throughDate: String?
    public var account: UsageAccountScope
    public var limitID: String?
    public var limit: Int
    public var offset: Int

    public init(timezone: String? = nil, fromDate: String? = nil, throughDate: String? = nil,
                account: UsageAccountScope = .all, limitID: String? = nil, limit: Int = 100, offset: Int = 0) {
        self.timezone = timezone; self.fromDate = fromDate; self.throughDate = throughDate
        self.account = account; self.limitID = limitID; self.limit = limit; self.offset = offset
    }

    func boundary(_ date: String?, afterDay: Bool, timezone: TimeZone) throws -> Double? {
        guard let date else { return nil }
        guard let utcDate = RolloutParser.parseDate(date + "T00:00:00Z") else { throw UsageQueryError.invalidDate }
        var utc = Calendar(identifier: .gregorian); utc.timeZone = .gmt
        let components = utc.dateComponents([.year, .month, .day], from: utcDate.addingTimeInterval(afterDay ? 86_400 : 0))
        var local = Calendar(identifier: .gregorian); local.timeZone = timezone
        guard let boundary = local.date(from: components) else { throw UsageQueryError.invalidDate }
        return boundary.timeIntervalSince1970
    }
}

public struct WeeklyLimitWindow: Codable, Sendable, Identifiable {
    public var id: String
    public let accountID: String?
    public let scopeKey: String
    public let limitID: String
    public let startedAtInferred: Int64
    public let scheduledResetAt: Int64
    public let firstObservedAt: Double
    public let firstPositiveAt: Double
    public let lastObservedAt: Double
    public let lastUsedPercent: Double?
    public let peakUsedPercent: Double
    public let observationCount: Int
    public let conflictingObservations: Int
    public let unknownAccountObservations: Int
    public let observedAccountIDs: [String]
    public let recoveryObservedAt: Double?
    public let sourceJSON: String
    // 百分比不能换算 token 或金额；也没有证据把最后观测冒充最终用量。
    public var totalTokens: Int64? = nil
    public var amountNanoUSD: Int64? = nil
    public var finalUsedPercent: Double? = nil
}

extension UsageAccountScope {
    var weeklyScopeKey: String {
        switch self {
        case .all: "all"
        case .unknown: "unknown"
        case .account(let id): "account:" + id
        }
    }
}

public struct WeeklyLimitHistory: Encodable, Sendable {
    public let timezone: String
    public let rows: [WeeklyLimitWindow]
    public let hasMore: Bool
    public let excludedObservations: [String: Int]
    public let coverage = "weekly_windows_by_inferred_start; recovery_time_separate; final_usage_and_account_attribution_may_be_unknown"
}

extension UsageStore {
    public func weeklyLimitHistory(_ query: LimitQuery = LimitQuery()) throws -> WeeklyLimitHistory {
        try UsageQuery(fromDate: query.fromDate, throughDate: query.throughDate, limit: query.limit, offset: query.offset).validate()
        let identifier = try query.timezone ?? statisticsTimezone()
        guard let timezone = TimeZone(identifier: identifier) else { throw UsageQueryError.invalidTimezone }
        let from = try query.boundary(query.fromDate, afterDay: false, timezone: timezone)
        let until = try query.boundary(query.throughDate, afterDay: true, timezone: timezone)
        while true {
            try Task.checkCancellation()
            try rebuildWeeklyCyclesIfNeeded(account: query.account)
            let result = try pool.read { db -> WeeklyLimitHistory? in
                guard try Self.weeklyCycleRevision(db) == String.fetchOne(db, sql: "SELECT value FROM app_metadata WHERE key=?", arguments: ["weekly_cache_revision:" + query.account.weeklyScopeKey]) else { return nil }
                // 按已固定窗口的起算日期查询，包含当前已开始使用的窗口。
                var clauses = ["query_scope = :scope"]
                var arguments: StatementArguments = ["limit": query.limit + 1, "offset": query.offset, "scope": query.account.weeklyScopeKey]
                if let id = query.limitID { clauses.append("limit_id = :bucket"); arguments += ["bucket": id] }
                if let from { clauses.append("event_at >= :from"); arguments += ["from": from] }
                if let until { clauses.append("event_at < :until"); arguments += ["until": until] }
                let rows = try String.fetchAll(db, sql: """
                    SELECT result_json FROM weekly_limit_cycles WHERE \(clauses.joined(separator: " AND "))
                    ORDER BY event_at DESC, id LIMIT :limit OFFSET :offset
                    """, arguments: arguments)
                let summary = try String.fetchOne(db, sql: "SELECT value FROM app_metadata WHERE key=?", arguments: ["weekly_cache_exclusions:" + query.account.weeklyScopeKey]) ?? "{}"
                return WeeklyLimitHistory(timezone: identifier,
                    rows: try rows.prefix(query.limit).map { try JSONDecoder().decode(WeeklyLimitWindow.self, from: Data($0.utf8)) },
                    hasMore: rows.count > query.limit,
                    excludedObservations: try JSONDecoder().decode([String: Int].self, from: Data(summary.utf8)))
            }
            if let result { return result }
        }
    }
}
