import Foundation

struct CodexDailyUsage: Codable, Sendable {
    let summary: Summary
    let dailyUsageBuckets: [Bucket]?
    struct Bucket: Codable, Sendable {
        let startDate: String
        let tokens: Int64
    }
    struct Summary: Codable, Sendable {
        let lifetimeTokens: Int64?
        let peakDailyTokens: Int64?
        let longestRunningTurnSec: Int64?
        let currentStreakDays: Int64?
        let longestStreakDays: Int64?
    }

    func validate() throws {
        var dates = Set<String>()
        for bucket in dailyUsageBuckets ?? [] {
            guard let parsed = RolloutParser.parseDate(bucket.startDate + "T00:00:00Z"),
                  parsed.formatted(.iso8601.year().month().day().dateSeparator(.dash)) == bucket.startDate, bucket.tokens >= 0,
                  dates.insert(bucket.startDate).inserted else { throw CodexAPIError.invalidStatistics }
        }
        for value in [summary.lifetimeTokens, summary.peakDailyTokens, summary.longestRunningTurnSec,
                      summary.currentStreakDays, summary.longestStreakDays].compactMap({ $0 }) {
            guard value >= 0 else { throw CodexAPIError.invalidStatistics }
        }
    }
}

struct CodexRateLimits: Codable, Sendable {
    let accountId: String?
    let rateLimits: Snapshot
    let rateLimitsByLimitId: [String: Snapshot]?
    struct Snapshot: Codable, Sendable {
        let limitId: String?
        let limitName: String?
        let planType: String?
        let primary: Window?
        let secondary: Window?
    }
    struct Window: Codable, Sendable {
        let usedPercent: Double
        let windowDurationMins: Int64?
        let resetsAt: Int64?

        var startsAt: Int64? {
            guard let duration = windowDurationMins, duration > 0, let reset = resetsAt else { return nil }
            let seconds = duration.multipliedReportingOverflow(by: 60)
            let start = reset.subtractingReportingOverflow(seconds.partialValue)
            return seconds.overflow || start.overflow ? nil : start.partialValue
        }
    }
}

public struct APISyncReport: Codable, Sendable {
    public let accountID: String?
    public let observedAt: Double?
    public let accountAvailable: Bool
    public let dailyBucketCount: Int?
    public let savedWindows: Int
    public let skippedWindows: Int
    public let reconciliation: String
    public let issue: String?

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(accountID, forKey: .accountID)
        try values.encode(observedAt, forKey: .observedAt)
        try values.encode(accountAvailable, forKey: .accountAvailable)
        try values.encode(dailyBucketCount, forKey: .dailyBucketCount)
        try values.encode(savedWindows, forKey: .savedWindows)
        try values.encode(skippedWindows, forKey: .skippedWindows)
        try values.encode(reconciliation, forKey: .reconciliation)
        try values.encode(issue, forKey: .issue)
    }
}

public struct LimitWindow: Codable, Sendable, Identifiable {
    public struct ID: Hashable, Sendable {
        public let account: String
        public let bucket: String
        public let kind: String
        public let reset: Int64
    }
    public var id: ID { ID(account: accountID, bucket: limitID, kind: kind, reset: resetsAt) }
    public let accountID: String
    public let limitID: String
    public let kind: String
    public let startsAt: Int64
    public let resetsAt: Int64
    public let durationMinutes: Int64
    public let lastUsedPercent: Double
    public let lastObservedAt: Double
    public let tokens: Int64?
    public let inputAmount: Int64?
    public let outputAmount: Int64?
    public let cacheReadAmount: Int64?
    public let cacheWriteAmount: Int64?
    public let unpricedTokens: Int64?
    public let sourceJSON: String?

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(accountID, forKey: .accountID)
        try values.encode(limitID, forKey: .limitID)
        try values.encode(kind, forKey: .kind)
        try values.encode(startsAt, forKey: .startsAt)
        try values.encode(resetsAt, forKey: .resetsAt)
        try values.encode(durationMinutes, forKey: .durationMinutes)
        try values.encode(lastUsedPercent, forKey: .lastUsedPercent)
        try values.encode(lastObservedAt, forKey: .lastObservedAt)
        try values.encode(tokens, forKey: .tokens)
        try values.encode(inputAmount, forKey: .inputAmount)
        try values.encode(outputAmount, forKey: .outputAmount)
        try values.encode(cacheReadAmount, forKey: .cacheReadAmount)
        try values.encode(cacheWriteAmount, forKey: .cacheWriteAmount)
        try values.encode(unpricedTokens, forKey: .unpricedTokens)
        try values.encode(sourceJSON, forKey: .sourceJSON)
    }
}
