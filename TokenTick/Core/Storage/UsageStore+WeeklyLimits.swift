import CryptoKit
import Foundation
import GRDB

extension UsageStore {
    static func saveWeeklyObservations(_ snapshot: CurrentLimitSnapshot, db: Database) throws -> Int {
        var inserted = 0
        for window in snapshot.windows where window.limitID == "codex" && window.durationMinutes == 10_080 {
            guard let reset = window.resetsAt, reset > 0 else { continue }
            let evidence = WeeklyEvidence(source: snapshot.source, fileName: snapshot.fileName, line: snapshot.line, window: window)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let json = String(decoding: try encoder.encode(evidence), as: UTF8.self)
            let signature = try JSONSerialization.data(withJSONObject: [snapshot.scopeKey, window.limitID,
                snapshot.observedAt, reset, window.usedPercent], options: [.sortedKeys])
            let key = SHA256.hash(data: signature).map { String(format: "%02x", $0) }.joined()
            try db.execute(sql: """
                INSERT INTO weekly_limit_observations(id, scope_key, account_id, limit_id, observed_at, resets_at, used_percent, source_json, turn_id, exclusion_reason, collected_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET turn_id=excluded.turn_id, exclusion_reason=excluded.exclusion_reason,
                    collected_at=excluded.collected_at, source_json=excluded.source_json
                WHERE weekly_limit_observations.turn_id IS NOT excluded.turn_id
                    OR weekly_limit_observations.exclusion_reason IS NOT excluded.exclusion_reason
                """, arguments: [key, snapshot.scopeKey, snapshot.accountID, window.limitID,
                                  snapshot.observedAt, reset, window.usedPercent, json, snapshot.turnID, snapshot.historyExclusion, Date().timeIntervalSince1970])
            inserted += db.changesCount
        }
        return inserted
    }

    private struct WeeklyEvidence: Codable {
        let source: String
        let fileName: String?
        let line: Int?
        let window: CurrentLimitWindow
    }
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
