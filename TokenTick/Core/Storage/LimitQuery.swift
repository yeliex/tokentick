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

public struct WeeklyLimitReset: Codable, Sendable, Identifiable {
    public let id: String
    public let accountID: String?
    public let scopeKey: String
    public let limitID: String
    public let scheduledResetAt: Int64
    public let detectedAt: Double
    public let lastObservedAt: Double
    public let usedPercentBeforeReset: Double
    public let kind: String
    public let sourceJSON: String
}

public struct WeeklyLimitHistory: Encodable, Sendable {
    public let timezone: String
    public let rows: [WeeklyLimitReset]
    public let hasMore: Bool
    public let coverage = "last_observation_before_reset; exact_final_usage_is_unknown"
}

extension UsageStore {
    /// 先按完整时间线识别边界，再按重置日期筛选；补入乱序历史会重新形成正确相邻关系。
    public func weeklyLimitHistory(_ query: LimitQuery = LimitQuery()) throws -> WeeklyLimitHistory {
        try UsageQuery(fromDate: query.fromDate, throughDate: query.throughDate, limit: query.limit, offset: query.offset).validate()
        let identifier = try query.timezone ?? statisticsTimezone()
        guard let timezone = TimeZone(identifier: identifier) else { throw UsageQueryError.invalidTimezone }
        let from = try query.boundary(query.fromDate, afterDay: false, timezone: timezone)
        let until = try query.boundary(query.throughDate, afterDay: true, timezone: timezone)
        return try pool.read { db in
            var clauses = ["previous_reset IS NOT NULL", "(resets_at != previous_reset OR (used_percent = 0 AND previous_percent > 0))"]
            var arguments: StatementArguments = ["limit": query.limit + 1, "offset": query.offset]
            switch query.account {
            case .all: break
            case .unknown: clauses.append("account_id IS NULL")
            case .account(let id): clauses.append("account_id = :account"); arguments += ["account": id]
            }
            if let id = query.limitID { clauses.append("limit_id = :bucket"); arguments += ["bucket": id] }
            let eventTime = "CASE WHEN observed_at >= previous_reset AND resets_at > previous_reset THEN previous_reset ELSE observed_at END"
            if let from { clauses.append("\(eventTime) >= :from"); arguments += ["from": from] }
            if let until { clauses.append("\(eventTime) < :until"); arguments += ["until": until] }
            let rows = try Row.fetchAll(db, sql: """
                WITH ordered AS (
                    SELECT *, LAG(id) OVER timeline AS previous_id,
                        LAG(observed_at) OVER timeline AS previous_observed,
                        LAG(resets_at) OVER timeline AS previous_reset,
                        LAG(used_percent) OVER timeline AS previous_percent,
                        LAG(source_json) OVER timeline AS previous_source
                    FROM weekly_limit_observations
                    WINDOW timeline AS (PARTITION BY scope_key, limit_id ORDER BY observed_at, id)
                )
                SELECT *, CASE
                    WHEN observed_at >= previous_reset AND resets_at > previous_reset THEN 'natural'
                    WHEN account_id IS NOT NULL AND used_percent < previous_percent THEN 'manual'
                    ELSE 'unconfirmed' END AS reset_kind
                FROM ordered WHERE \(clauses.joined(separator: " AND "))
                ORDER BY observed_at DESC, id LIMIT :limit OFFSET :offset
                """, arguments: arguments)
            return WeeklyLimitHistory(timezone: identifier, rows: rows.prefix(query.limit).map { row in
                WeeklyLimitReset(id: row["id"], accountID: row["account_id"], scopeKey: row["scope_key"], limitID: row["limit_id"],
                    scheduledResetAt: row["previous_reset"], detectedAt: row["observed_at"], lastObservedAt: row["previous_observed"],
                    usedPercentBeforeReset: row["previous_percent"], kind: row["reset_kind"], sourceJSON: row["previous_source"])
            }, hasMore: rows.count > query.limit)
        }
    }
}
