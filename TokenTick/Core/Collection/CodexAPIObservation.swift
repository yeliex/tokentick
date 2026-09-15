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
            guard let parsed = DateParsing.parseTimestamp(bucket.startDate + "T00:00:00Z"),
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
    }
}

struct CodexAccountResponse: Decodable, Sendable {
    let account: Account?
    struct Account: Decodable, Sendable {
        let type: String
        let email: String?
    }

    func subscriptionEmail(before: CodexRateLimits, after: CodexRateLimits) -> String? {
        guard let id = before.accountId, !id.isEmpty, id == after.accountId,
              account?.type == "chatgpt",
              let email = account?.email?.trimmingCharacters(in: .whitespacesAndNewlines),
              !email.isEmpty else { return nil }
        return email
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
    public var accountEmail: String? = nil
    public var currentLimits: CurrentLimitSnapshot? = nil

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(accountID, forKey: .accountID)
        try values.encode(accountEmail, forKey: .accountEmail)
        try values.encode(observedAt, forKey: .observedAt)
        try values.encode(accountAvailable, forKey: .accountAvailable)
        try values.encode(dailyBucketCount, forKey: .dailyBucketCount)
        try values.encode(savedWindows, forKey: .savedWindows)
        try values.encode(skippedWindows, forKey: .skippedWindows)
        try values.encode(reconciliation, forKey: .reconciliation)
        try values.encode(issue, forKey: .issue)
    }
}
