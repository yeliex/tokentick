import Foundation
import GRDB

extension UsageStore {
    public func usageSummaries(grouping: UsageGrouping = .day, limit: Int = 100) throws -> [UsageSummary] {
        try usageReport(UsageQuery(grouping: grouping, limit: limit)).rows
    }

    /// Return paginated summaries; rebuild stale caches without loading all historical records into the caller.
    public func usageReport(_ query: UsageQuery = UsageQuery()) throws -> UsageReport {
        try query.validate()
        let identifier = try query.timezone ?? statisticsTimezone()
        guard let timezone = TimeZone(identifier: identifier) else { throw UsageQueryError.invalidTimezone }
        if try query.filters.isEmpty && !pool.read({ try Self.statisticsAreCurrent($0, timezone: timezone.identifier) }) {
            do { _ = try rebuildStatistics(timezone: timezone, onlyIfNeeded: true, nonBlocking: true) }
            catch FileWriteLock.LockError.busy {
                // Read committed facts while the scanner holds the process lock instead of blocking the UI for the full scan.
            }
        }
        return try pool.read { try Self.readUsageReport(query, timezone: timezone, db: $0) }
    }

    static func readUsageReport(_ query: UsageQuery, timezone: TimeZone, db: Database, dateExpression: String? = nil) throws -> UsageReport {
        try Task.checkCancellation()
        // Another process may write after rebuilding; fall back to fact aggregation within the same read snapshot.
        let current = try dateExpression == nil && query.filters.isEmpty && Self.statisticsAreCurrent(db, timezone: timezone.identifier)
        if !current { StatisticsSQL.prepare(db, timezone: timezone) }
        let factFilters = UsageFiltersSQL(query.filters)
        let source = current ? "" : "WITH statistics(\(StatisticsSQL.columns)) AS (\(StatisticsSQL.aggregate(predicate: factFilters.predicate, dateExpression: dateExpression, query: query))) "
        let dimension = [.total, .day].contains(query.grouping) ? "all" : query.grouping.rawValue
        let group = switch query.grouping {
        case .total: "NULL"
        case .day: "CASE WHEN date = 'unknown' THEN NULL ELSE date END"
        default: "CASE WHEN dimension_value = 'unknown' THEN NULL ELSE substr(dimension_value, 7) END"
        }
        var arguments: StatementArguments = ["timezone": timezone.identifier, "account": query.account.key,
                                             "dimension": dimension, "limit": query.limit + 1, "offset": query.offset]
        arguments += factFilters.arguments
        var filters = "timezone = :timezone AND account_key = :account AND dimension = :dimension"
        if let from = query.fromDate {
            filters += " AND date != 'unknown' AND date >= :from"
            arguments += ["from": from]
        }
        if let through = query.throughDate {
            filters += " AND date != 'unknown' AND date <= :through"
            arguments += ["through": through]
        }
        let order: String
        switch query.sort {
        case .automatic: order = query.grouping == .day ? "group_value IS NULL, group_value DESC" : "total_tokens DESC, group_value ASC"
        case .tokens: order = "total_tokens DESC, group_value ASC"
        case .amount: order = "known_amount IS NULL, known_amount DESC, group_value ASC"
        case .name:
            order = query.grouping == .thread
                ? "COALESCE((SELECT title FROM threads WHERE thread_id = group_value), group_value) COLLATE NOCASE ASC, group_value ASC"
                : "group_value ASC"
        }
        let rows = try Row.fetchAll(db, sql: """
            \(source)SELECT \(group) AS group_value, COUNT(*) OVER() AS total_groups, SUM(record_count) AS records,
                MIN(MIN(NULLIF(date, 'unknown'))) OVER() AS data_from_date,
                MAX(MAX(NULLIF(date, 'unknown'))) OVER() AS data_through_date,
                SUM(total_tokens) AS total_tokens, SUM(input_tokens) AS input_tokens,
                SUM(output_tokens) AS output_tokens, SUM(cache_read_tokens) AS cache_read_tokens,
                SUM(cache_write_tokens) AS cache_write_tokens, SUM(reasoning_tokens) AS reasoning_tokens,
                SUM(known_amount) AS known_amount, SUM(input_amount) AS input_amount,
                SUM(output_amount) AS output_amount, SUM(cache_read_amount) AS cache_read_amount,
                SUM(cache_write_amount) AS cache_write_amount, SUM(complete_amount) AS complete_amount,
                SUM(unpriced_tokens) AS unpriced_tokens, SUM(unpriced_records) AS unpriced_records,
                SUM(unattributed_tokens) AS unattributed_tokens
            FROM statistics WHERE \(filters) GROUP BY group_value
            ORDER BY \(order)
            LIMIT :limit OFFSET :offset
            """, arguments: arguments)
        try Task.checkCancellation()
        // Unknown-date reporting needs only token totals, not component repricing or aggregation of every date.
        let unknownSQL = current ? """
            SELECT SUM(total_tokens) FROM statistics
            WHERE timezone = :timezone AND account_key = :account AND dimension = 'all' AND date = 'unknown'
            """ : """
            SELECT SUM(u.total_tokens) FROM usage u LEFT JOIN threads t ON t.thread_id = u.thread_id
            WHERE (u.source = 'local' OR u.thread_id IS NOT NULL) AND (\(factFilters.predicate))
                AND (\(dateExpression ?? StatisticsSQL.dayExpression)) = 'unknown'
                AND (:account = 'all' OR CASE WHEN u.account_id IS NULL THEN 'unknown'
                     ELSE 'value:' || u.account_id END = :account)
            """
        let unknown = try Int64.fetchOne(db, sql: unknownSQL,
            arguments: ["timezone": timezone.identifier, "account": query.account.key] + factFilters.arguments) ?? 0
        var totalGroups: Int = rows.first?["total_groups"] ?? 0
        if rows.isEmpty && query.offset > 0 {
            var countArguments: StatementArguments = ["timezone": timezone.identifier, "account": query.account.key, "dimension": dimension]
            countArguments += factFilters.arguments
            if let from = query.fromDate { countArguments += ["from": from] }
            if let through = query.throughDate { countArguments += ["through": through] }
            totalGroups = try Int.fetchOne(db, sql: "\(source)SELECT COUNT(*) FROM (SELECT \(group) AS group_value FROM statistics WHERE \(filters) GROUP BY group_value)", arguments: countArguments) ?? 0
        }
        let summaries = rows.prefix(query.limit).map(UsageSummary.init(row:))
        return UsageReport(timezone: timezone.identifier, grouping: query.grouping, fromDate: query.fromDate,
                           throughDate: query.throughDate, unknownDateTokens: unknown, rows: summaries, hasMore: rows.count > query.limit, totalGroups: totalGroups,
                           dataFromDate: rows.first?["data_from_date"], dataThroughDate: rows.first?["data_through_date"])
    }
}


public struct UsageFilterOptions: Sendable, Equatable {
    public let models: [String]
    public let projects: [String]
    public let accounts: [String]
}

extension UsageStore {
    /// Load options independently of selected values so a filter cannot hide alternative choices.
    public func usageFilterOptions(_ query: UsageQuery = UsageQuery()) throws -> UsageFilterOptions {
        try query.validate()
        let identifier = try query.timezone ?? statisticsTimezone()
        guard let timezone = TimeZone(identifier: identifier) else { throw UsageQueryError.invalidTimezone }
        return try pool.read { db in
            StatisticsSQL.prepare(db, timezone: timezone)
            var filters = UsageFilters()
            filters.occurredFrom = query.filters.occurredFrom
            filters.occurredBefore = query.filters.occurredBefore
            let scope = UsageFiltersSQL(filters)
            var predicate = "(u.source = 'local' OR u.thread_id IS NOT NULL) AND (\(scope.predicate))"
            var arguments = scope.arguments
            if query.fromDate != nil || query.throughDate != nil { arguments += ["timezone": identifier] }
            if let from = query.fromDate {
                predicate += " AND (\(StatisticsSQL.dayExpression)) >= :from AND (\(StatisticsSQL.dayExpression)) != 'unknown'"
                arguments += ["from": from]
            }
            if let through = query.throughDate {
                predicate += " AND (\(StatisticsSQL.dayExpression)) <= :through AND (\(StatisticsSQL.dayExpression)) != 'unknown'"
                arguments += ["through": through]
            }
            switch query.account {
            case .all: break
            case .unknown: predicate += " AND u.account_id IS NULL"
            case .account(let id): predicate += " AND u.account_id = :account"; arguments += ["account": id]
            }
            let models = try String.fetchAll(db, sql: "SELECT DISTINCT u.model FROM usage u WHERE \(predicate) AND u.model IS NOT NULL ORDER BY u.model", arguments: arguments)
            let projects = try String.fetchAll(db, sql: "SELECT DISTINCT t.project_name FROM usage u JOIN threads t ON t.thread_id = u.thread_id WHERE \(predicate) AND t.project_name IS NOT NULL ORDER BY t.project_name", arguments: arguments)
            let accounts = try String.fetchAll(db, sql: """
                SELECT account_id FROM usage WHERE account_id IS NOT NULL
                UNION SELECT account_id FROM weekly_limit_cycles WHERE account_id IS NOT NULL
                ORDER BY account_id
                """)
            return UsageFilterOptions(models: models, projects: projects, accounts: accounts)
        }
    }
}
