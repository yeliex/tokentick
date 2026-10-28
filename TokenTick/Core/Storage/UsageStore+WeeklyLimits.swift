import Foundation
import GRDB

extension UsageStore {
    public func currentWeeklyLimitUsage(accountID: String, resetsAt: Int64) throws -> WeeklyLimitWindow? {
        try Task.checkCancellation()
        let memory = weeklyMemory.withLock { $0 }
        guard let cycle = memory.resolvedCycles().first(where: {
            $0.window.account == accountID && abs($0.window.reset - resetsAt) <= 60 && !$0.early
        }) else { return nil }
        return try pool.read { db in
            try Task.checkCancellation()
            StatisticsSQL.prepare(db, timezone: .gmt)
            // Match history's turn attribution, including responses that arrive after their turn's cycle.
            let row = try Row.fetchOne(db, sql: """
                WITH turns AS MATERIALIZED (
                    SELECT turn_key,MIN(turn_started_at) AS started FROM usage
                    WHERE turn_key IS NOT NULL GROUP BY turn_key
                )
                SELECT COUNT(*) AS requests,COALESCE(SUM(u.total_tokens),0) AS tokens,
                    CASE WHEN COUNT(*)=COUNT(u.amount) THEN SUM(u.amount) END AS amount,
                    SUM(tokentick_known_amount(u.input_amount,u.output_amount,u.cache_read_amount,u.cache_write_amount,u.amount)) AS known
                FROM usage u LEFT JOIN turns t ON t.turn_key=u.turn_key
                WHERE u.source='local' AND u.account_id=?
                    AND COALESCE(t.started,u.occurred_at)>=? AND COALESCE(t.started,u.occurred_at)<?
                """, arguments: [accountID,cycle.start,resetsAt])!
            try Task.checkCancellation()
            return WeeklyLimitWindow(id: "current:" + accountID, accountID: accountID, limitID: "codex",
                startedAtInferred: Int64(cycle.start), scheduledResetAt: resetsAt,
                lastObservedAt: cycle.window.last, lastUsedPercent: cycle.window.percent,
                resetKind: "natural", endsAt: Double(resetsAt), totalTokens: row["tokens"],
                amountNanoUSD: row["amount"], knownAmountNanoUSD: row["known"], requestCount: row["requests"])
        }
    }

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
