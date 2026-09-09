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
        let rawLimits = try JSONSerialization.jsonObject(with: Data(limitsJSON.utf8)) as? [String: Any]
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
                var saved = 0
                var skipped = 0
                if let account {
                    let observed = observedAt.timeIntervalSince1970
                    for (key, snapshot) in buckets {
                        let rawBucket = (rawLimits?["rateLimitsByLimitId"] as? [String: Any])?[key]
                            ?? (limits.rateLimitsByLimitId == nil ? rawLimits?["rateLimits"] : nil)
                        let json = try rawBucket.map {
                            String(decoding: try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), as: UTF8.self)
                        } ?? String(decoding: encoder.encode(snapshot), as: UTF8.self)
                        for (kind, candidate) in [("primary", snapshot.primary), ("secondary", snapshot.secondary)] {
                            guard let window = candidate else { continue }
                            guard let start = window.startsAt, let reset = window.resetsAt,
                                  let duration = window.windowDurationMins else { skipped += 1; continue }
                            try db.execute(sql: """
                                INSERT INTO limit_windows(account_id, limit_id, window_kind, resets_at,
                                    window_duration_mins, starts_at, used_percent, last_observed_at, source_json)
                                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                                ON CONFLICT(account_id, limit_id, window_kind, resets_at) DO UPDATE SET
                                    window_duration_mins = excluded.window_duration_mins, starts_at = excluded.starts_at,
                                    used_percent = excluded.used_percent, last_observed_at = excluded.last_observed_at,
                                    source_json = excluded.source_json
                                WHERE excluded.last_observed_at >= limit_windows.last_observed_at
                                """, arguments: [account, key, kind, reset, duration, start, window.usedPercent, observed, json])
                            saved += db.changesCount
                        }
                    }
                    for bucket in daily?.dailyUsageBuckets ?? [] {
                        try db.execute(sql: """
                            INSERT INTO api_daily_usage(account_id, start_date, tokens, fetched_at) VALUES (?, ?, ?, ?)
                            ON CONFLICT(account_id, start_date) DO UPDATE SET tokens = excluded.tokens, fetched_at = excluded.fetched_at
                            WHERE excluded.fetched_at >= api_daily_usage.fetched_at
                            """, arguments: [account, bucket.startDate, bucket.tokens, observed])
                    }
                    let dateKey = "api_last_observed:\(account)"
                    let previous = try Double.fetchOne(db, sql: "SELECT CAST(value AS REAL) FROM app_metadata WHERE key = ?", arguments: [dateKey])
                    if previous.map({ observed >= $0 }) ?? true {
                        for (key, value) in [(dateKey, String(observed)), ("api_limits:\(account)", limitsJSON),
                                             ("api_daily:\(account)", dailyJSON)] {
                            guard let value else { continue }
                            try db.execute(sql: "INSERT INTO app_metadata(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                                           arguments: [key, value])
                        }
                    }
                }
                // 接口日桶没有时区／token 口径字段，历史日志也没有账号证据。
                // 在这些契约确定前只保存服务端事实，不创建会与本地重复的 API 差额。
                let report = APISyncReport(accountAvailable: account != nil,
                                           dailyBucketCount: account == nil ? nil : daily?.dailyUsageBuckets?.count,
                                           savedWindows: saved, skippedWindows: skipped,
                                           reconciliation: "unverified_account_and_daily_semantics", issue: issue)
                try db.execute(sql: "INSERT INTO app_metadata(key, value) VALUES ('api_last_report', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                               arguments: [String(decoding: try encoder.encode(report), as: UTF8.self)])
                return report
            }
        }
    }

    public func limitWindows(limit: Int = 100, currentOnly: Bool = false) throws -> [LimitWindow] {
        try pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM limit_windows
                \(currentOnly ? "WHERE last_observed_at = (SELECT CAST(value AS REAL) FROM app_metadata WHERE key = 'api_last_observed:' || account_id)" : "")
                ORDER BY last_observed_at DESC, resets_at DESC, account_id, limit_id, window_kind LIMIT ?
                """, arguments: [min(max(limit, 1), 10_000)]).map { row in
                LimitWindow(accountID: row["account_id"], limitID: row["limit_id"], kind: row["window_kind"],
                            startsAt: row["starts_at"], resetsAt: row["resets_at"], durationMinutes: row["window_duration_mins"],
                            lastUsedPercent: row["used_percent"], lastObservedAt: row["last_observed_at"], tokens: row["tokens"],
                            inputAmount: row["input_amount"], outputAmount: row["output_amount"],
                            cacheReadAmount: row["cache_read_amount"], cacheWriteAmount: row["cache_write_amount"], unpricedTokens: row["unpriced_tokens"])
            }
        }
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
    public let accountID: String
    public let date: String
    public let tokens: Int64
    public let fetchedAt: Double
}
