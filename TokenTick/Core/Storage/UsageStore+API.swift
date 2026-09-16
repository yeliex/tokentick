import Foundation
import GRDB

extension UsageStore {
    static func prepareAPIObservation(limits: CodexRateLimits, daily: CodexDailyUsage?, observedAt: Date,
                            issue: String? = nil, limitsSourceJSON: String? = nil, accountEmail: String? = nil) throws -> APISyncReport {
        try daily?.validate()
        guard observedAt.timeIntervalSince1970.isFinite else { throw CodexAPIError.invalidStatistics }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let limitsJSON = try limitsSourceJSON ?? String(decoding: encoder.encode(limits), as: UTF8.self)
        let account = limits.accountId.flatMap { $0.isEmpty ? nil : $0 }
        let buckets = limits.rateLimitsByLimitId ?? limits.rateLimits.limitId.map { [$0: limits.rateLimits] } ?? [:]
        for (key, snapshot) in buckets {
            guard !key.isEmpty, snapshot.limitId == nil || snapshot.limitId == key else { throw CodexAPIError.invalidStatistics }
            for window in [snapshot.primary, snapshot.secondary].compactMap({ $0 }) {
                guard window.usedPercent.isFinite, window.usedPercent >= 0 else { throw CodexAPIError.invalidStatistics }
            }
        }
        let snapshot = try CurrentLimitSnapshot.parse(Data(limitsJSON.utf8), accountID: account,
            observedAt: observedAt.timeIntervalSince1970, source: "api", scopeKey: account.map { "account:" + $0 } ?? "api:unknown")
        let saved = 0
        let skipped = snapshot.windows.filter { $0.limitID == "codex" && $0.durationMinutes == 10_080 && $0.resetsAt == nil }.count
        var report = APISyncReport(accountID: account, observedAt: observedAt.timeIntervalSince1970,
                                   accountAvailable: account != nil,
                                   dailyBucketCount: daily?.dailyUsageBuckets?.count,
                                   savedWindows: saved, skippedWindows: skipped,
                                   reconciliation: "in_memory_reference_difference", issue: issue)
        report.accountEmail = accountEmail
        report.currentLimits = snapshot
        return report
    }

    func saveAPIObservation(limits: CodexRateLimits, daily: CodexDailyUsage?, observedAt: Date,
                            issue: String? = nil, limitsSourceJSON: String? = nil, accountEmail: String? = nil) throws -> APISyncReport {
        let report = try Self.prepareAPIObservation(limits: limits, daily: daily, observedAt: observedAt,
            issue: issue, limitsSourceJSON: limitsSourceJSON, accountEmail: accountEmail)
        try saveAPIObservation(report, daily: daily, observedAt: observedAt)
        return report
    }

    func saveAPIObservation(_ report: APISyncReport, daily: CodexDailyUsage?, observedAt: Date) throws {
        try FileWriteLock(url: databaseURL.appendingPathExtension("write.lock")).withLock {
            try pool.write { db in try Self.saveAPIReport(report, db: db) }
            if let snapshot = report.currentLimits {
                try observeWeeklyLimits([snapshot])
                _ = try saveCompletedWeeklyCycles(now: observedAt)
            }
            apiMemory.withLock { memory in
                guard observedAt.timeIntervalSince1970 >= memory.observedAt else { return }
                // Clear reference buckets on account changes or missing API data to prevent account leakage.
                memory = APIMemory(observedAt: observedAt.timeIntervalSince1970, accountID: report.accountID, daily: daily)
            }
        }
    }

    func saveAPIFailure(_ issue: String, observedAt: Date = Date()) throws {
        guard observedAt.timeIntervalSince1970.isFinite else { throw CodexAPIError.invalidStatistics }
        let report = APISyncReport(accountID: nil, observedAt: observedAt.timeIntervalSince1970,
            accountAvailable: false, dailyBucketCount: nil, savedWindows: 0, skippedWindows: 0,
            reconciliation: "in_memory_reference_difference", issue: issue)
        try FileWriteLock(url: databaseURL.appendingPathExtension("write.lock")).withLock {
            try pool.write { db in try Self.saveAPIReport(report, db: db) }
            apiMemory.withLock { memory in
                if observedAt.timeIntervalSince1970 >= memory.observedAt {
                    memory = APIMemory(observedAt: observedAt.timeIntervalSince1970)
                }
            }
        }
    }

    private static func saveAPIReport(_ report: APISyncReport, db: Database) throws {
        let previous = try String.fetchOne(db, sql: "SELECT value FROM app_metadata WHERE key = 'api_last_report'")
            .map { try JSONDecoder().decode(APISyncReport.self, from: Data($0.utf8)) }
        // Keep source status across local syncs; older observations must not overwrite newer failures or accounts.
        if let previousDate = previous?.observedAt, let date = report.observedAt, previousDate > date { return }
        let json = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        try db.execute(sql: "INSERT INTO app_metadata(key, value) VALUES ('api_last_report', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                       arguments: [json])
    }

    public func apiDailyUsage(limit: Int = 100) throws -> [APIDailyBucket] {
        let memory = apiMemory.withLock { $0 }
        let buckets = Array((memory.daily?.dailyUsageBuckets ?? []).sorted { $0.startDate > $1.startDate }
            .prefix(min(max(limit, 1), 10_000)))
        guard !buckets.isEmpty else { return [] }
        return try pool.read { db in
            try buckets.map { bucket in
                // API bucket timezone is unspecified; UTC alignment is a reference with unknown-account coverage reported separately.
                let row = try Row.fetchOne(db, sql: """
                    SELECT COALESCE(SUM(total_tokens),0) AS covered,
                        COALESCE(SUM(CASE WHEN account_id IS NULL THEN total_tokens ELSE 0 END),0) AS unknown
                    FROM usage WHERE source='local' AND usage_date=?
                        AND (? IS NULL OR account_id=? OR account_id IS NULL)
                    """, arguments: [bucket.startDate,memory.accountID,memory.accountID])!
                let covered: Int64 = row["covered"]
                let difference = bucket.tokens - covered
                return APIDailyBucket(accountID: memory.accountID, date: bucket.startDate, tokens: bucket.tokens,
                    fetchedAt: memory.observedAt, localTokens: covered, unknownAccountLocalTokens: row["unknown"],
                    differenceTokens: difference, otherTokens: max(0,difference))
            }
        }
    }
}

struct APIMemory: Sendable {
    var observedAt: Double = -.infinity
    var accountID: String?
    var daily: CodexDailyUsage?
}

public struct APIDailyBucket: Encodable, Sendable {
    public let accountID: String?
    public let date: String
    public let tokens: Int64
    public let fetchedAt: Double
    public let localTokens: Int64
    public let unknownAccountLocalTokens: Int64
    public let differenceTokens: Int64
    public let otherTokens: Int64
    public var comparison: String { "reference_estimate_utc_account_coverage_unverified" }

    enum CodingKeys: String, CodingKey {
        case accountID, date, tokens, fetchedAt, localTokens, unknownAccountLocalTokens, differenceTokens, otherTokens, comparison
    }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(accountID, forKey: .accountID)
        try values.encode(date, forKey: .date)
        try values.encode(tokens, forKey: .tokens)
        try values.encode(fetchedAt, forKey: .fetchedAt)
        try values.encode(localTokens, forKey: .localTokens)
        try values.encode(unknownAccountLocalTokens, forKey: .unknownAccountLocalTokens)
        try values.encode(differenceTokens, forKey: .differenceTokens)
        try values.encode(otherTokens, forKey: .otherTokens)
        try values.encode(comparison, forKey: .comparison)
    }
}
