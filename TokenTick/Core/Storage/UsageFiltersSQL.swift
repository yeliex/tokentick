import GRDB

/// Filter summaries and records in SQLite; never aggregate a limited result page as the full dataset.
struct UsageFiltersSQL {
    let predicate: String
    let arguments: StatementArguments

    init(_ filters: UsageFilters) {
        var parts: [String] = []
        var values = StatementArguments()
        for (key, column, filter) in [
            ("thread", "u.thread_id", filters.thread), ("project", "t.project_name", filters.project),
            ("model", "u.model", filters.model), ("day", "NULLIF(\(StatisticsSQL.dayExpression), 'unknown')", filters.day)
        ] {
            switch filter {
            case .all: break
            case .unknown: parts.append("\(column) IS NULL")
            case .value(let value):
                parts.append("\(column) = :filter_\(key)")
                values += StatementArguments(["filter_\(key)": value])
            }
        }
        if !filters.search.isEmpty {
            parts.append("(tokentick_contains(t.title, :filter_search) OR tokentick_contains(u.thread_id, :filter_search))")
            values += ["filter_search": filters.search]
        }
        if let from = filters.occurredFrom {
            parts.append("u.occurred_at >= :occurred_from")
            values += ["occurred_from": from]
        }
        if let before = filters.occurredBefore {
            parts.append("u.occurred_at < :occurred_before")
            values += ["occurred_before": before]
        }
        predicate = parts.isEmpty ? "1" : parts.joined(separator: " AND ")
        arguments = values
    }
}
