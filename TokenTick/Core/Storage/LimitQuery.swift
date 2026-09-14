import Foundation

public struct LimitQuery: Sendable, Hashable {
    public var timezone: String?
    public var fromDate: String?
    public var throughDate: String?
    public var account: UsageAccountScope
    public var limitID: String?
    public var limit: Int
    public var offset: Int

    public init(timezone: String? = nil, fromDate: String? = nil, throughDate: String? = nil,
                account: UsageAccountScope = .all, limitID: String? = nil, limit: Int = 100, offset: Int = 0) {
        self.timezone = timezone; self.fromDate = fromDate; self.throughDate = throughDate
        self.account = account; self.limitID = limitID; self.limit = limit; self.offset = offset
    }

    func boundary(_ date: String?, afterDay: Bool, timezone: TimeZone) throws -> Double? {
        guard let date else { return nil }
        guard let utcDate = DateParsing.parseTimestamp(date + "T00:00:00Z") else { throw UsageQueryError.invalidDate }
        var utc = Calendar(identifier: .gregorian); utc.timeZone = .gmt
        let components = utc.dateComponents([.year, .month, .day], from: utcDate.addingTimeInterval(afterDay ? 86_400 : 0))
        var local = Calendar(identifier: .gregorian); local.timeZone = timezone
        guard let boundary = local.date(from: components) else { throw UsageQueryError.invalidDate }
        return boundary.timeIntervalSince1970
    }
}

public struct WeeklyLimitWindow: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public let accountID: String?
    public let scopeKey: String
    public let limitID: String
    public let startedAtInferred: Int64
    public let scheduledResetAt: Int64
    public let firstObservedAt: Double
    public let firstPositiveAt: Double
    public let lastObservedAt: Double
    public let lastUsedPercent: Double?
    public let peakUsedPercent: Double
    public let observationCount: Int
    public let conflictingObservations: Int
    public let unknownAccountObservations: Int
    public let observedAccountIDs: [String]
    public let recoveryObservedAt: Double?
    public let sourceJSON: String
    // 金额与 tokens 来自本地明细；最后额度观测仍不能冒充重置时的最终百分比。
    public var totalTokens: Int64? = nil
    public var amountNanoUSD: Int64? = nil
    public var finalUsedPercent: Double? = nil
    public var knownAmountNanoUSD: Int64? = nil
    public var unpricedTokens: Int64? = nil
    public var usageEndsAt: Int64? = nil
    public var actualResetAt: Double? = nil
    public var requestCount: Int? = nil
    public var endsAt: Double { actualResetAt ?? Double(usageEndsAt ?? scheduledResetAt) }
    public var usageAttribution: String = "local_usage_by_turn_start_in_query_account_scope"
}

extension UsageAccountScope {
    var weeklyScopeKey: String {
        switch self {
        case .all: "all"
        case .unknown: "unknown"
        case .account(let id): "account:" + id
        }
    }
}

public struct WeeklyLimitHistory: Encodable, Sendable {
    public let timezone: String
    public let rows: [WeeklyLimitWindow]
    public let hasMore: Bool
    public let excludedObservations: [String: Int]
    public let coverage = "weekly_windows_by_inferred_start; recovery_time_separate; final_usage_and_account_attribution_may_be_unknown"
}
