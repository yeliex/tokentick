import Foundation
import GRDB

extension UsageStore {
    static func weeklyCycleRevision(_ db: Database) throws -> String {
        "3:" + (try String.fetchOne(db, sql: "SELECT value FROM app_metadata WHERE key='weekly_revision'") ?? "0")
    }

    func rebuildWeeklyCyclesIfNeeded(account: UsageAccountScope) throws {
        let scope = account.weeklyScopeKey
        let revisionKey = "weekly_cache_revision:" + scope
        let needed = try pool.read { db in
            try Self.weeklyCycleRevision(db) != String.fetchOne(db, sql: "SELECT value FROM app_metadata WHERE key=?", arguments: [revisionKey])
        }
        guard needed else { return }
        try FileWriteLock(url: databaseURL.appendingPathExtension("write.lock")).withLock {
            try pool.write { db in
                let revision = try Self.weeklyCycleRevision(db)
                if try String.fetchOne(db, sql: "SELECT value FROM app_metadata WHERE key=?", arguments: [revisionKey]) == revision { return }
                var filter = "1"
                var arguments = StatementArguments()
                switch account {
                case .all: break
                case .unknown: filter = "w.account_id IS NULL"
                case .account(let id): filter = "w.account_id=?"; arguments = [id]
                }
                // 仅物化紧凑的数值证据；JSON 只在生成窗口结果时按主键读取。
                try db.execute(sql: """
                    CREATE TEMP TABLE weekly_evidence AS
                    SELECT w.id,w.account_id,w.observed_at,w.resets_at,w.used_percent,CASE
                        WHEN w.exclusion_reason IS NOT NULL THEN w.exclusion_reason
                        WHEN t.thread_id IS NOT NULL AND w.scope_key LIKE 'thread:%'
                            AND t.thread_id != substr(w.scope_key,8) THEN 'fork_turn'
                        WHEN json_extract(s.parser_state_json,'$.session.forked_from_id') IS NOT NULL
                            AND abs(w.observed_at-unixepoch(json_extract(s.parser_state_json,'$.session.timestamp'),'subsec'))<=2
                            THEN 'fork_creation_replay'
                        WHEN w.observed_at >= w.resets_at THEN 'expired'
                        WHEN w.resets_at-w.observed_at > 604805 THEN 'invalid_window'
                        ELSE NULL END AS excluded
                    FROM weekly_limit_observations w
                    LEFT JOIN turn_usage t ON t.turn_id=w.turn_id
                    LEFT JOIN scan_files s ON s.file_name=json_extract(w.source_json,'$.fileName')
                    WHERE w.limit_id='codex'
                        AND COALESCE(json_extract(w.source_json,'$.window.durationMinutes'),10080)=10080
                        AND \(filter)
                    """, arguments: arguments)
                defer { try? db.execute(sql: "DROP TABLE IF EXISTS temp.weekly_evidence") }
                var excluded: [String: Int] = [:]
                for row in try Row.fetchAll(db, sql: "SELECT excluded,COUNT(*) AS n FROM weekly_evidence WHERE excluded IS NOT NULL GROUP BY excluded") {
                    excluded[row["excluded"]] = row["n"]
                }
                try db.execute(sql: """
                    DELETE FROM weekly_evidence WHERE excluded IS NOT NULL;
                    CREATE INDEX temp.weekly_evidence_account_time ON weekly_evidence(account_id,observed_at);
                    UPDATE weekly_evidence SET excluded='conflicting_deadlines'
                    WHERE account_id IS NOT NULL AND (account_id,observed_at) IN (
                        SELECT account_id,observed_at FROM weekly_evidence WHERE account_id IS NOT NULL
                        GROUP BY account_id,observed_at HAVING MAX(resets_at)-MIN(resets_at)>60
                    );
                    """)
                excluded["conflicting_deadlines"] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM weekly_evidence WHERE excluded IS NOT NULL") ?? 0
                try db.execute(sql: "DELETE FROM weekly_evidence WHERE excluded IS NOT NULL; CREATE INDEX temp.weekly_evidence_reset ON weekly_evidence(resets_at)")
                let cursor = try Row.fetchCursor(db, sql: """
                    WITH timed AS (
                        SELECT *,MIN(observed_at) OVER w AS first_at,MAX(observed_at) OVER w AS last_at,
                            MIN(CASE WHEN used_percent>0 THEN observed_at END) OVER w AS first_positive
                        FROM weekly_evidence WINDOW w AS (PARTITION BY resets_at)
                    ), summaries AS (
                        SELECT resets_at,COUNT(*) AS n,SUM(used_percent>0) AS positive_count,
                            first_at,last_at,first_positive,MAX(used_percent) AS peak,
                            MIN(CASE WHEN observed_at=last_at THEN used_percent END) AS last_min,
                            MAX(CASE WHEN observed_at=last_at THEN used_percent END) AS last_max,
                            SUM(account_id IS NULL) AS unknown_count,json_group_array(DISTINCT account_id) AS accounts,
                            MIN(CASE WHEN observed_at=first_at THEN id END) AS first_id,
                            MIN(CASE WHEN observed_at=last_at THEN id END) AS last_id,
                            MIN(CASE WHEN observed_at=first_positive AND used_percent>0 THEN id END) AS positive_id
                        FROM timed GROUP BY resets_at
                    )
                    SELECT s.*,f.source_json AS first_source,l.source_json AS last_source,p.source_json AS positive_source
                    FROM summaries s
                    JOIN weekly_limit_observations f ON f.id=s.first_id
                    JOIN weekly_limit_observations l ON l.id=s.last_id
                    LEFT JOIN weekly_limit_observations p ON p.id=s.positive_id
                    ORDER BY s.resets_at
                    """)
                var calculator = WeeklyCycleCalculator(scope: account)
                while let row = try cursor.next() {
                    try Task.checkCancellation()
                    let accountsJSON: String = row["accounts"]
                    let accounts = try JSONDecoder().decode([String?].self, from: Data(accountsJSON.utf8)).compactMap { $0 }
                    calculator.consume(.init(reset: row["resets_at"], count: row["n"], positiveCount: row["positive_count"],
                        firstTime: row["first_at"], firstPositiveTime: row["first_positive"], lastTime: row["last_at"],
                        lastMinPercent: row["last_min"], lastMaxPercent: row["last_max"], peak: row["peak"],
                        unknownCount: row["unknown_count"], accounts: accounts, firstSource: row["first_source"],
                        lastSource: row["last_source"], positiveSource: row["positive_source"]))
                }
                let windows = try calculator.windows(recoveries: Self.weeklyRecoveries(db))
                try Task.checkCancellation()
                // 同一筛选范围内原子发布；全局、未知及明确账号各自缓存，不互相补归属。
                let previous = try Row.fetchAll(db, sql: "SELECT id,scheduled_reset_at FROM weekly_limit_cycles WHERE query_scope=?", arguments: [scope])
                var reused: Set<String> = []
                try db.execute(sql: "DELETE FROM weekly_limit_cycles WHERE query_scope=?", arguments: [scope])
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                for var window in windows {
                    // 截止代表秒值或最早证据变化时，保留已存在窗口的标识。
                    let matches = previous.filter { row in
                        let oldID: String = row["id"], oldReset: Int64 = row["scheduled_reset_at"]
                        return !reused.contains(oldID) && abs(oldReset-window.scheduledResetAt)<=WeeklyCycleCalculator.deadlineTolerance
                    }
                    if matches.count == 1 { window.id = matches[0]["id"]; reused.insert(window.id) }
                    let json = String(decoding: try encoder.encode(window), as: UTF8.self)
                    try db.execute(sql: "INSERT INTO weekly_limit_cycles(id,account_id,limit_id,scheduled_reset_at,event_at,result_json,query_scope) VALUES (?,?,?,?,?,?,?)",
                        arguments: [window.id,window.accountID,window.limitID,window.scheduledResetAt,window.startedAtInferred,json,scope])
                }
                let summary = String(decoding: try encoder.encode(excluded), as: UTF8.self)
                for (key,value) in [(revisionKey,revision),("weekly_cache_exclusions:" + scope,summary)] {
                    try db.execute(sql: "INSERT INTO app_metadata(key,value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", arguments: [key,value])
                }
            }
        }
    }

    private static func weeklyRecoveries(_ db: Database) throws -> [WeeklyCycleCalculator.Recovery] {
        // 只有账号明确的正值→零值→新窗口正值能关联恢复观测；不猜未知日志的账号。
        let rows = try Row.fetchCursor(db, sql: """
            SELECT e.*,w.source_json FROM weekly_evidence e JOIN weekly_limit_observations w ON w.id=e.id
            WHERE e.account_id IS NOT NULL ORDER BY e.account_id,e.observed_at,e.id
            """)
        var account: String?
        var previous: (time: Double, reset: Int64, percent: Double)?
        var pending: (time: Double, source: String)?
        var results: [WeeklyCycleCalculator.Recovery] = []
        while let row = try rows.next() {
            try Task.checkCancellation()
            let id: String = row["account_id"]
            if account != id { account = id; previous = nil; pending = nil }
            let time: Double = row["observed_at"], reset: Int64 = row["resets_at"], percent: Double = row["used_percent"]
            if percent == 0 {
                if let previous, time > previous.time, abs(reset-previous.reset)>WeeklyCycleCalculator.deadlineTolerance, pending == nil {
                    pending = (time,row["source_json"])
                }
            } else {
                if let pending, let previous, time > pending.time, percent < previous.percent,
                   abs(reset-previous.reset)>WeeklyCycleCalculator.deadlineTolerance {
                    results.append(.init(account: id, reset: reset, observedAt: pending.time, source: pending.source))
                }
                pending = nil; previous = (time,reset,percent)
            }
        }
        return results
    }
}
