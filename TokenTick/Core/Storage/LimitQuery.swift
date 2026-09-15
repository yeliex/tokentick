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
    public let id: String
    public let accountID: String?
    public let limitID: String
    public let startedAtInferred: Int64
    public let scheduledResetAt: Int64
    public let lastObservedAt: Double
    public let lastUsedPercent: Double?
    public let resetKind: String
    public let endsAt: Double
    public let totalTokens: Int64?
    public let amountNanoUSD: Int64?
    public let knownAmountNanoUSD: Int64?
    public let requestCount: Int?
    public var observedAccountIDs: [String] { accountID.map { [$0] } ?? [] }
}

public struct WeeklyLimitHistory: Encodable, Sendable {
    public let timezone: String
    public let rows: [WeeklyLimitWindow]
    public let hasMore: Bool
}
