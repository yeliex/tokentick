import Foundation
import GRDB

extension UsageStore {
    func observeWeeklyLimits(_ snapshots: [CurrentLimitSnapshot]) throws {
        let accepted = try pool.read { try Self.acceptedWeeklyLimits(snapshots, db: $0) }
        weeklyMemory.withLock { memory in
            for snapshot in accepted { memory.consume(snapshot) }
        }
    }

    static func acceptedWeeklyLimits(_ snapshots: [CurrentLimitSnapshot], db: Database) throws -> [CurrentLimitSnapshot] {
        // 轮次归属由请求明细判断，fork 中继承的窗口不参与周期识别。
        try snapshots.filter { snapshot in
            guard snapshot.historyExclusion == nil else { return false }
            if let turn = snapshot.turnID, snapshot.scopeKey.hasPrefix("thread:"),
               let owner = try String.fetchOne(db, sql: "SELECT thread_id FROM usage WHERE turn_key=? LIMIT 1", arguments: ["turn:" + turn]) {
                return owner == String(snapshot.scopeKey.dropFirst(7))
            }
            return true
        }
    }

    @discardableResult
    func saveCompletedWeeklyCycles(now: Date = Date()) throws -> Int {
        let memory = weeklyMemory.withLock { $0 }
        return try pool.write { db in
            let changed = try memory.saveCompleted(db: db, now: now.timeIntervalSince1970)
            try Self.refreshWeeklyCycleUsage(db, force: changed > 0)
            return changed
        }
    }

    static func refreshWeeklyCycleUsage(_ db: Database, force: Bool = false) throws {
        let revision = try statisticsRevision(db)
        let saved = try Int64.fetchOne(db, sql: "SELECT CAST(value AS INTEGER) FROM app_metadata WHERE key='weekly_cycles_revision'")
        guard force || saved != revision else { return }
        StatisticsSQL.prepare(db, timezone: .gmt)
        // 一次计算轮次起点和全部周期，避免每个周期、每条请求重复查询轮次。
        let rows = try Row.fetchAll(db, sql: """
            WITH turns AS MATERIALIZED (
                SELECT turn_key,MIN(turn_started_at) AS started FROM usage
                WHERE turn_key IS NOT NULL GROUP BY turn_key
            ), facts AS MATERIALIZED (
                SELECT u.*,COALESCE(t.started,u.occurred_at) AS cycle_time
                FROM usage u LEFT JOIN turns t ON t.turn_key=u.turn_key WHERE u.source='local'
            )
            SELECT c.id,COUNT(f.id) AS requests,COALESCE(SUM(f.total_tokens),0) AS tokens,
                CASE WHEN COUNT(f.id)=COUNT(f.amount) THEN SUM(f.amount) END AS amount,
                SUM(tokentick_known_amount(f.input_amount,f.output_amount,f.cache_read_amount,f.cache_write_amount,f.amount)) AS known
            FROM weekly_limit_cycles c LEFT JOIN facts f
                ON f.account_id IS c.account_id AND f.cycle_time>=c.started_at AND f.cycle_time<c.ended_at
            GROUP BY c.id
            """)
        for row in rows {
            try Task.checkCancellation()
            try db.execute(sql: """
                UPDATE weekly_limit_cycles SET total_tokens=?,request_count=?,amount=?,known_amount=? WHERE id=?
                """, arguments: [row["tokens"],row["requests"],row["amount"],row["known"],row["id"]])
        }
        try db.execute(sql: """
            INSERT INTO app_metadata(key,value) VALUES ('weekly_cycles_revision',?)
            ON CONFLICT(key) DO UPDATE SET value=excluded.value
            """, arguments: [String(revision)])
    }

}
