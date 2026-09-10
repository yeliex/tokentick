import Foundation
import GRDB

extension UsageStore {
    private static let weeklyEvidenceSQL = """
        WITH classified AS (
            SELECT w.*, CASE
                WHEN w.exclusion_reason IS NOT NULL THEN w.exclusion_reason
                WHEN t.thread_id IS NOT NULL AND w.scope_key LIKE 'thread:%'
                    AND t.thread_id != substr(w.scope_key,8) THEN 'fork_turn'
                WHEN json_extract(s.parser_state_json,'$.session.forked_from_id') IS NOT NULL
                    AND abs(w.observed_at-unixepoch(json_extract(s.parser_state_json,'$.session.timestamp'),'subsec'))<=2
                    THEN 'fork_creation_replay'
                WHEN w.observed_at >= w.resets_at THEN 'expired'
                WHEN w.resets_at-w.observed_at > 604802 THEN 'invalid_window'
                ELSE NULL END AS excluded
            FROM weekly_limit_observations w
            LEFT JOIN turn_usage t ON t.turn_id=w.turn_id
            LEFT JOIN scan_files s ON s.file_name=json_extract(w.source_json,'$.fileName')
            WHERE w.limit_id='codex'
        )
        """

    static func weeklyCycleRevision(_ db: Database) throws -> String {
        // 算法变化时递增前缀，避免无新观测时继续展示旧算法的缓存。
        "2:" + (try String.fetchOne(db, sql: "SELECT value FROM app_metadata WHERE key='weekly_revision'") ?? "0")
    }

    func rebuildWeeklyCyclesIfNeeded() throws {
        let needed = try pool.read { db in
            try Self.weeklyCycleRevision(db) != String.fetchOne(db, sql: "SELECT value FROM app_metadata WHERE key='weekly_cache_revision'")
        }
        guard needed else { return }
        try FileWriteLock(url: databaseURL.appendingPathExtension("write.lock")).withLock {
            try pool.write { db in
                let revision = try Self.weeklyCycleRevision(db)
                if try String.fetchOne(db, sql: "SELECT value FROM app_metadata WHERE key='weekly_cache_revision'") == revision { return }
                var excluded: [String: Int] = [:]
                for row in try Row.fetchAll(db, sql: Self.weeklyEvidenceSQL + " SELECT excluded,COUNT(*) AS n FROM classified WHERE excluded IS NOT NULL GROUP BY excluded") {
                    excluded[row["excluded"]] = row["n"]
                }
                let cursor = try Row.fetchCursor(db, sql: Self.weeklyEvidenceSQL + """
                    , unknown_groups AS (
                        SELECT limit_id,resets_at,MIN(observed_at) AS first_at,MAX(observed_at) AS last_at,
                            MAX(used_percent) AS peak_percent,COUNT(*) AS n
                        FROM classified WHERE excluded IS NULL AND account_id IS NULL AND used_percent>0
                        GROUP BY limit_id,resets_at
                    ), points AS (
                        SELECT MIN(id) AS id,account_id,limit_id,observed_at,MIN(resets_at) AS resets_at,
                            MIN(used_percent) AS used_percent,COUNT(*) AS n,
                            (MAX(resets_at)-MIN(resets_at)>2 OR MAX(used_percent)!=MIN(used_percent)) AS conflict,
                            NULL AS first_at,NULL AS peak_percent,0 AS last_conflicted
                        FROM classified WHERE excluded IS NULL AND account_id IS NOT NULL
                        GROUP BY account_id,limit_id,observed_at
                        UNION ALL
                        SELECT MIN(c.id),NULL,g.limit_id,g.last_at,g.resets_at,MIN(c.used_percent),g.n,0,
                            g.first_at,g.peak_percent,MAX(c.used_percent)!=MIN(c.used_percent)
                        FROM unknown_groups g JOIN classified c
                            ON c.account_id IS NULL AND c.limit_id=g.limit_id AND c.resets_at=g.resets_at
                                AND c.observed_at=g.last_at AND c.excluded IS NULL AND c.used_percent>0
                        GROUP BY g.limit_id,g.resets_at
                    )
                    SELECT p.*,c.source_json FROM points p JOIN classified c ON c.id=p.id
                    ORDER BY p.account_id,p.limit_id,CASE WHEN p.account_id IS NULL THEN p.resets_at ELSE 0 END,p.observed_at,p.id
                    """)
                var calculator = WeeklyCycleCalculator()
                while let row = try cursor.next() {
                    try Task.checkCancellation()
                    try calculator.consume(.init(id: row["id"], account: row["account_id"], limit: row["limit_id"],
                        time: row["observed_at"], reset: row["resets_at"], percent: row["used_percent"],
                        count: row["n"], conflict: row["conflict"], source: row["source_json"],
                        firstObservedAt: row["first_at"], peakPercent: row["peak_percent"], lastConflicted: row["last_conflicted"]))
                }
                try calculator.finish()
                excluded["conflicting_or_isolated_drop_points"] = calculator.conflictCount
                // 周期结果规模小；在单事务内发布，失败或取消保留之前缓存，重试整次重建。
                try db.execute(sql: "DELETE FROM weekly_limit_cycles")
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                for cycle in calculator.results {
                    let json = String(decoding: try encoder.encode(cycle), as: UTF8.self)
                    let eventAt = cycle.resetAt ?? cycle.resetBefore
                    try db.execute(sql: "INSERT INTO weekly_limit_cycles(id,account_id,limit_id,scheduled_reset_at,event_at,result_json) VALUES (?,?,?,?,?,?)",
                        arguments: [cycle.id,cycle.accountID,cycle.limitID,cycle.scheduledResetAt,eventAt,json])
                }
                let summary = String(decoding: try encoder.encode(excluded), as: UTF8.self)
                for (key,value) in [("weekly_cache_revision",revision),("weekly_cache_exclusions",summary)] {
                    try db.execute(sql: "INSERT INTO app_metadata(key,value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", arguments: [key,value])
                }
            }
        }
    }
}
