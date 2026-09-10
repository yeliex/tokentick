import Foundation
import GRDB

extension UsageStore {
    func saveAPIObservation(limits: CodexRateLimits, daily: CodexDailyUsage?, observedAt: Date,
                            issue: String? = nil, limitsSourceJSON: String? = nil, dailySourceJSON: String? = nil) throws -> APISyncReport {
        try daily?.validate()
        guard observedAt.timeIntervalSince1970.isFinite else { throw CodexAPIError.invalidStatistics }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let limitsJSON = try limitsSourceJSON ?? String(decoding: encoder.encode(limits), as: UTF8.self)
        let dailyJSON = try dailySourceJSON ?? daily.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
        let account = limits.accountId.flatMap { $0.isEmpty ? nil : $0 }
        let buckets = limits.rateLimitsByLimitId ?? limits.rateLimits.limitId.map { [$0: limits.rateLimits] } ?? [:]
        for (key, snapshot) in buckets {
            guard !key.isEmpty, snapshot.limitId == nil || snapshot.limitId == key else { throw CodexAPIError.invalidStatistics }
            for window in [snapshot.primary, snapshot.secondary].compactMap({ $0 }) {
                guard window.usedPercent.isFinite, window.usedPercent >= 0 else { throw CodexAPIError.invalidStatistics }
            }
        }
        return try FileWriteLock(url: databaseURL.appendingPathExtension("write.lock")).withLock {
            try pool.write { db in
                let snapshot = try CurrentLimitSnapshot.parse(Data(limitsJSON.utf8), accountID: account,
                    observedAt: observedAt.timeIntervalSince1970, source: "api", scopeKey: account.map { "account:" + $0 } ?? "api:unknown")
                let saved = try Self.saveWeeklyObservations(snapshot, db: db)
                let skipped = snapshot.windows.filter { $0.durationMinutes == 10_080 && $0.resetsAt == nil }.count
                let observed = observedAt.timeIntervalSince1970
                for bucket in daily?.dailyUsageBuckets ?? [] {
                    try db.execute(sql: """
                        INSERT INTO api_daily_usage(account_id, start_date, tokens, fetched_at) VALUES (?, ?, ?, ?)
                        ON CONFLICT DO UPDATE SET tokens = excluded.tokens, fetched_at = excluded.fetched_at
                        WHERE excluded.fetched_at >= api_daily_usage.fetched_at
                        """, arguments: [account, bucket.startDate, bucket.tokens, observed])
                }
                if let dailyJSON {
                    let key = account.map { "api_daily:" + $0 } ?? "api_daily:unknown"
                    let previous = try Double.fetchOne(db, sql: "SELECT CAST(value AS REAL) FROM app_metadata WHERE key = ?", arguments: [key + ":observed"])
                    if previous.map({ observed >= $0 }) ?? true {
                        for (key, value) in [(key, dailyJSON), (key + ":observed", String(observed))] {
                            try db.execute(sql: "INSERT INTO app_metadata(key,value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", arguments: [key,value])
                        }
                    }
                }
                // 无法归属到任务的服务端桶独立保存，不加入本地统计或猜测差额。
                var report = APISyncReport(accountID: account, observedAt: observedAt.timeIntervalSince1970,
                                           accountAvailable: account != nil,
                                           dailyBucketCount: daily?.dailyUsageBuckets?.count,
                                           savedWindows: saved, skippedWindows: skipped,
                                           reconciliation: "unattributed_api_excluded_from_local_totals", issue: issue)
                report.currentLimits = snapshot
                try Self.saveAPIReport(report, db: db)
                return report
            }
        }
    }

    func saveAPIFailure(_ issue: String, observedAt: Date = Date()) throws {
        guard observedAt.timeIntervalSince1970.isFinite else { throw CodexAPIError.invalidStatistics }
        let report = APISyncReport(accountID: nil, observedAt: observedAt.timeIntervalSince1970,
            accountAvailable: false, dailyBucketCount: nil, savedWindows: 0, skippedWindows: 0,
            reconciliation: "unattributed_api_excluded_from_local_totals", issue: issue)
        try FileWriteLock(url: databaseURL.appendingPathExtension("write.lock")).withLock {
            try pool.write { db in try Self.saveAPIReport(report, db: db) }
        }
    }

    private static func saveAPIReport(_ report: APISyncReport, db: Database) throws {
        let previous = try String.fetchOne(db, sql: "SELECT value FROM app_metadata WHERE key = 'api_last_report'")
            .map { try JSONDecoder().decode(APISyncReport.self, from: Data($0.utf8)) }
        // 独立来源状态跨本地同步保留；较早完成的观测不能覆盖更新的失败或账号。
        if let previousDate = previous?.observedAt, let date = report.observedAt, previousDate > date { return }
        let json = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        try db.execute(sql: "INSERT INTO app_metadata(key, value) VALUES ('api_last_report', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                       arguments: [json])
    }

    public func apiDailyUsage(limit: Int = 100) throws -> [APIDailyBucket] {
        try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM api_daily_usage ORDER BY start_date DESC, account_id LIMIT ?",
                             arguments: [min(max(limit, 1), 10_000)]).map { row in
                APIDailyBucket(accountID: row["account_id"], date: row["start_date"], tokens: row["tokens"], fetchedAt: row["fetched_at"])
            }
        }
    }
}

public struct APIDailyBucket: Codable, Sendable {
    public let accountID: String?
    public let date: String
    public let tokens: Int64
    public let fetchedAt: Double
}
