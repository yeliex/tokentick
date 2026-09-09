import Foundation
import GRDB

public enum LimitWindowKind: String, CaseIterable, Sendable { case primary, secondary }

public struct LimitQuery: Sendable, Hashable {
    public var timezone: String?
    public var fromDate: String?
    public var throughDate: String?
    public var account: UsageAccountScope
    public var limitID: String?
    public var kind: LimitWindowKind?
    public var latestOnly: Bool
    public var limit: Int
    public var offset: Int

    public init(timezone: String? = nil, fromDate: String? = nil, throughDate: String? = nil,
                account: UsageAccountScope = .all, limitID: String? = nil, kind: LimitWindowKind? = nil,
                latestOnly: Bool = false, limit: Int = 100, offset: Int = 0) {
        self.timezone = timezone; self.fromDate = fromDate; self.throughDate = throughDate
        self.account = account; self.limitID = limitID; self.kind = kind; self.latestOnly = latestOnly
        self.limit = limit; self.offset = offset
    }

    func boundary(_ date: String?, afterDay: Bool, timezone: TimeZone) throws -> Double? {
        guard let date else { return nil }
        guard let utcDate = RolloutParser.parseDate(date + "T00:00:00Z") else { throw UsageQueryError.invalidDate }
        var utc = Calendar(identifier: .gregorian); utc.timeZone = .gmt
        let components = utc.dateComponents([.year, .month, .day], from: utcDate.addingTimeInterval(afterDay ? 86_400 : 0))
        var local = Calendar(identifier: .gregorian); local.timeZone = timezone
        guard let boundary = local.date(from: components) else { throw UsageQueryError.invalidDate }
        return boundary.timeIntervalSince1970
    }
}

public struct LimitWindowPage: Encodable, Sendable {
    public let timezone: String
    public let fromDate: String?
    public let throughDate: String?
    public let latestOnly: Bool
    public let rows: [LimitWindow]
    public let hasMore: Bool
    public let amountUnit = "nanoUSD"
    public let coverage = "observed_windows; last percentage is not a final percentage"
}

extension UsageStore {
    /// 日期选择与窗口 [starts_at, resets_at) 重叠的记录，不把跨日窗口拆分或按比例分摊。
    public func limitWindowPage(_ query: LimitQuery = LimitQuery()) throws -> LimitWindowPage {
        try UsageQuery(fromDate: query.fromDate, throughDate: query.throughDate, limit: query.limit, offset: query.offset).validate()
        let identifier = try query.timezone ?? statisticsTimezone()
        guard let timezone = TimeZone(identifier: identifier) else { throw UsageQueryError.invalidTimezone }
        let from = try query.boundary(query.fromDate, afterDay: false, timezone: timezone)
        let until = try query.boundary(query.throughDate, afterDay: true, timezone: timezone)
        return try pool.read { db in
            var clauses = ["1"]
            if let from, let until, from >= until { clauses.append("0") }
            var arguments: StatementArguments = ["limit": query.limit + 1, "offset": query.offset]
            switch query.account {
            case .all: break
            case .unknown: clauses.append("0")
            case .account(let id): clauses.append("account_id = :account"); arguments += ["account": id]
            }
            if query.latestOnly {
                clauses.append("last_observed_at = (SELECT CAST(value AS REAL) FROM app_metadata WHERE key = 'api_last_observed:' || account_id)")
            }
            if let from { clauses.append("resets_at > :from"); arguments += ["from": from] }
            if let until { clauses.append("starts_at < :until"); arguments += ["until": until] }
            if let id = query.limitID { clauses.append("limit_id = :bucket"); arguments += ["bucket": id] }
            if let kind = query.kind { clauses.append("window_kind = :kind"); arguments += ["kind": kind.rawValue] }
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM limit_windows WHERE \(clauses.joined(separator: " AND "))
                ORDER BY last_observed_at DESC, resets_at DESC, account_id, limit_id, window_kind
                LIMIT :limit OFFSET :offset
                """, arguments: arguments)
            return LimitWindowPage(timezone: timezone.identifier, fromDate: query.fromDate, throughDate: query.throughDate,
                latestOnly: query.latestOnly, rows: rows.prefix(query.limit).map { row in
                    LimitWindow(accountID: row["account_id"], limitID: row["limit_id"], kind: row["window_kind"],
                        startsAt: row["starts_at"], resetsAt: row["resets_at"], durationMinutes: row["window_duration_mins"],
                        lastUsedPercent: row["used_percent"], lastObservedAt: row["last_observed_at"], tokens: row["tokens"],
                        inputAmount: row["input_amount"], outputAmount: row["output_amount"],
                        cacheReadAmount: row["cache_read_amount"], cacheWriteAmount: row["cache_write_amount"],
                        unpricedTokens: row["unpriced_tokens"], sourceJSON: row["source_json"])
                }, hasMore: rows.count > query.limit)
        }
    }
}
