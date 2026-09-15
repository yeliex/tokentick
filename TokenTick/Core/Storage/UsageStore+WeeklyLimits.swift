import Foundation
import GRDB

extension UsageStore {
    public func weeklyLimitHistory(_ query: LimitQuery = LimitQuery()) throws -> WeeklyLimitHistory {
        try UsageQuery(fromDate: query.fromDate, throughDate: query.throughDate, limit: query.limit, offset: query.offset).validate()
        let identifier = try query.timezone ?? statisticsTimezone()
        guard let timezone = TimeZone(identifier: identifier) else { throw UsageQueryError.invalidTimezone }
        let from = try query.boundary(query.fromDate, afterDay: false, timezone: timezone)
        let until = try query.boundary(query.throughDate, afterDay: true, timezone: timezone)
        return try pool.read { db in
            var clauses = ["1"]
            var arguments: StatementArguments = ["limit": query.limit + 1, "offset": query.offset]
            if let from { clauses.append("started_at >= :from"); arguments += ["from": from] }
            if let until { clauses.append("started_at < :until"); arguments += ["until": until] }
            if let id = query.limitID { clauses.append("limit_id = :bucket"); arguments += ["bucket": id] }
            switch query.account {
            case .all: break
            case .unknown: clauses.append("account_id IS NULL")
            case .account(let id): clauses.append("account_id = :account"); arguments += ["account": id]
            }
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM weekly_limit_cycles WHERE \(clauses.joined(separator: " AND "))
                ORDER BY started_at DESC,id LIMIT :limit OFFSET :offset
                """, arguments: arguments)
            let windows = rows.prefix(query.limit).map { row -> WeeklyLimitWindow in
                let account: String? = row["account_id"]
                let start: Double = row["started_at"], end: Double = row["ended_at"]
                return WeeklyLimitWindow(id: row["id"], accountID: account, limitID: row["limit_id"],
                    startedAtInferred: Int64(start), scheduledResetAt: row["scheduled_reset_at"],
                    lastObservedAt: row["last_observed_at"], lastUsedPercent: row["last_used_percent"],
                    resetKind: row["reset_kind"], endsAt: end, totalTokens: row["total_tokens"],
                    amountNanoUSD: row["amount"], knownAmountNanoUSD: row["known_amount"], requestCount: row["request_count"])
            }
            return WeeklyLimitHistory(timezone: identifier, rows: windows, hasMore: rows.count > query.limit)
        }
    }
}
