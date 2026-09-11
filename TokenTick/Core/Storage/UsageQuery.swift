import Foundation

public enum UsageGrouping: String, CaseIterable, Codable, Sendable {
    case total, day, thread, project, model
}

public enum UsageValueFilter: Sendable, Equatable, Hashable {
    case all, unknown, value(String)
    public init(_ value: String?) { self = value.map(Self.value) ?? .unknown }
}

public struct UsageFilters: Sendable, Equatable, Hashable {
    public var thread: UsageValueFilter = .all
    public var project: UsageValueFilter = .all
    public var model: UsageValueFilter = .all
    public var day: UsageValueFilter = .all
    public var search = ""
    public init() {}
    public var isEmpty: Bool { thread == .all && project == .all && model == .all && day == .all && search.isEmpty }
}

public enum UsageSort: String, Sendable, CaseIterable {
    case automatic, tokens, amount, name
}

public enum UsageAccountScope: Sendable, Hashable {
    case all, unknown, account(String)
    var key: String {
        switch self {
        case .all: "all"
        case .unknown: "unknown"
        case .account(let id): "value:" + id
        }
    }
}

public struct UsageQuery: Sendable, Hashable {
    public var grouping: UsageGrouping
    public var timezone: String?
    public var fromDate: String?
    public var throughDate: String?
    public var account: UsageAccountScope
    public var limit: Int
    public var offset: Int
    public var filters: UsageFilters
    public var sort: UsageSort

    public init(grouping: UsageGrouping = .day, timezone: String? = nil, fromDate: String? = nil,
                throughDate: String? = nil, account: UsageAccountScope = .all, limit: Int = 100, offset: Int = 0,
                filters: UsageFilters = UsageFilters(), sort: UsageSort = .automatic) {
        self.grouping = grouping
        self.timezone = timezone
        self.fromDate = fromDate
        self.throughDate = throughDate
        self.account = account
        self.limit = limit
        self.offset = offset
        self.filters = filters
        self.sort = sort
    }

    /// 从已展示的分组继续下钻，保留其他维度与日期条件。
    public func focused(on grouping: UsageGrouping, value: String?) -> Self {
        var query = self
        switch grouping {
        case .total: break
        case .day: query.filters.day = UsageValueFilter(value)
        case .thread: query.filters.thread = UsageValueFilter(value)
        case .project: query.filters.project = UsageValueFilter(value)
        case .model: query.filters.model = UsageValueFilter(value)
        }
        query.offset = 0
        return query
    }

    func validate() throws {
        guard (1...10_000).contains(limit), offset >= 0 else { throw UsageQueryError.invalidPagination }
        let focusedDate: String? = if case .value(let date) = filters.day { date } else { nil }
        for date in [fromDate, throughDate, focusedDate].compactMap({ $0 }) {
            guard let parsed = DateParsing.parseTimestamp(date + "T00:00:00Z"),
                  parsed.formatted(.iso8601.year().month().day().dateSeparator(.dash)) == date else {
                throw UsageQueryError.invalidDate
            }
        }
        if let fromDate, let throughDate, fromDate > throughDate { throw UsageQueryError.invalidRange }
    }
}

public struct UsageReport: Codable, Sendable {
    public let timezone: String
    public let grouping: UsageGrouping
    public let fromDate: String?
    public let throughDate: String?
    public let unknownDateTokens: Int64
    public let rows: [UsageSummary]
    public let hasMore: Bool
    public var amountUnit: String { "nanoUSD" }

    enum CodingKeys: String, CodingKey { case timezone, grouping, fromDate, throughDate, unknownDateTokens, rows, hasMore, amountUnit }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        timezone = try values.decode(String.self, forKey: .timezone)
        grouping = try values.decode(UsageGrouping.self, forKey: .grouping)
        fromDate = try values.decodeIfPresent(String.self, forKey: .fromDate)
        throughDate = try values.decodeIfPresent(String.self, forKey: .throughDate)
        unknownDateTokens = try values.decode(Int64.self, forKey: .unknownDateTokens)
        rows = try values.decode([UsageSummary].self, forKey: .rows)
        hasMore = try values.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
    }
    init(timezone: String, grouping: UsageGrouping, fromDate: String?, throughDate: String?, unknownDateTokens: Int64, rows: [UsageSummary], hasMore: Bool = false) {
        self.timezone = timezone
        self.grouping = grouping
        self.fromDate = fromDate
        self.throughDate = throughDate
        self.unknownDateTokens = unknownDateTokens
        self.rows = rows
        self.hasMore = hasMore
    }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(timezone, forKey: .timezone)
        try values.encode(grouping, forKey: .grouping)
        try values.encode(fromDate, forKey: .fromDate)
        try values.encode(throughDate, forKey: .throughDate)
        try values.encode(unknownDateTokens, forKey: .unknownDateTokens)
        try values.encode(rows, forKey: .rows)
        try values.encode(hasMore, forKey: .hasMore)
        try values.encode(amountUnit, forKey: .amountUnit)
    }
}

public enum UsageQueryError: Error, LocalizedError {
    case invalidTimezone, invalidDate, invalidRange, invalidPagination
    public var errorDescription: String? {
        switch self {
        case .invalidTimezone: "统计时区必须是有效的 IANA 时区。"
        case .invalidDate: "筛选日期必须为有效的 YYYY-MM-DD。"
        case .invalidRange: "开始日期不能晚于结束日期。"
        case .invalidPagination: "limit 必须为 1–10000，offset 不能为负数。"
        }
    }
}
