import Foundation
import GRDB

extension UsageStore {
    /// 只读取当前页的统计字段与证据。标题、项目和文件位置取最新缓存，不复制到用量事实中。
    public func usageRecords(_ query: UsageQuery = UsageQuery(), scope: UsageRecordScope = .all) throws -> UsageRecordPage {
        try query.validate()
        if case .day(let date?) = scope { try UsageQuery(fromDate: date).validate() }
        let identifier = try query.timezone ?? statisticsTimezone()
        guard let timezone = TimeZone(identifier: identifier) else { throw UsageQueryError.invalidTimezone }
        return try pool.read { db in
            StatisticsSQL.prepare(db, timezone: timezone)
            var arguments: StatementArguments = ["timezone": timezone.identifier, "limit": query.limit + 1, "offset": query.offset]
            let shared = UsageFiltersSQL(query.filters)
            arguments += shared.arguments
            var filters = [shared.predicate]
            switch query.account {
            case .all: break
            case .unknown: filters.append("u.account_id IS NULL")
            case .account(let id): filters.append("u.account_id = :account"); arguments += ["account": id]
            }
            switch scope {
            case .all: break
            case .thread(let id): filters.append("u.thread_id IS :scope"); arguments += ["scope": id]
            case .project(let name): filters.append("t.project_name IS :scope"); arguments += ["scope": name]
            case .model(let model): filters.append("u.model IS :scope"); arguments += ["scope": model]
            case .day(let date): filters.append("statistical_date IS :scope"); arguments += ["scope": date]
            }
            if let from = query.fromDate { filters.append("statistical_date >= :from"); arguments += ["from": from] }
            if let through = query.throughDate { filters.append("statistical_date <= :through"); arguments += ["through": through] }
            let order: String
            switch query.sort {
            case .automatic: order = "u.occurred_at DESC, u.id DESC"
            case .tokens: order = "u.total_tokens DESC, u.id DESC"
            case .amount: order = "known_amount IS NULL, known_amount DESC, u.id DESC"
            case .name: order = "COALESCE(t.title, u.thread_id) COLLATE NOCASE ASC, u.id DESC"
            }
            let rows = try Row.fetchAll(db, sql: """
                SELECT u.*, t.title, t.project_name, f.file_name, f.current_path,
                    NULLIF(\(StatisticsSQL.dayExpression), 'unknown') AS statistical_date,
                    tokentick_known_amount(u.input_amount, u.output_amount, u.cache_read_amount, u.cache_write_amount, u.amount) AS known_amount
                FROM usage u LEFT JOIN threads t ON t.thread_id = u.thread_id
                LEFT JOIN scan_files f ON f.rollout_id = u.rollout_id
                WHERE \(filters.joined(separator: " AND "))
                ORDER BY \(order) LIMIT :limit OFFSET :offset
                """, arguments: arguments)
            return UsageRecordPage(timezone: timezone.identifier, rows: rows.prefix(query.limit).map(UsageRecord.init(row:)),
                                   hasMore: rows.count > query.limit)
        }
    }
}
