import Foundation
import GRDB

enum StatisticsSQL {
    // 汇总和明细共用日期口径；只有 UTC 日日期的事实不能在其他时区猜测归属。
    static let dayExpression = """
        CASE WHEN u.occurred_at IS NOT NULL THEN COALESCE(tokentick_day(u.occurred_at), 'unknown')
             WHEN :timezone IN ('UTC', 'GMT') THEN COALESCE(u.usage_date, 'unknown')
             ELSE 'unknown' END
        """

    static func prepare(_ db: Database, timezone: TimeZone) {
        db.add(function: DatabaseFunction("tokentick_contains", argumentCount: 2, pure: true) { values in
            guard let text = String.fromDatabaseValue(values[0]), let term = String.fromDatabaseValue(values[1]) else { return false }
            return text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")) != nil
        })
        let style = Date.ISO8601FormatStyle(timeZone: timezone).year().month().day().dateSeparator(.dash)
        db.add(function: DatabaseFunction("tokentick_day", argumentCount: 1, pure: true) { values in
            guard let timestamp = Double.fromDatabaseValue(values[0]), timestamp.isFinite else { return nil }
            return autoreleasepool { Date(timeIntervalSince1970: timestamp).formatted(style) }
        })
        db.add(function: DatabaseFunction("tokentick_known_amount", argumentCount: 5, pure: true) { values in
            var amount: Int64 = 0
            for value in values.prefix(4) {
                guard let component = Int64.fromDatabaseValue(value) else { continue }
                let sum = amount.addingReportingOverflow(component)
                guard !sum.overflow else { throw PriceError.amountOverflow }
                amount = sum.partialValue
            }
            return amount == 0 && values[4].isNull ? nil : amount
        })
    }

    static let groupColumns = "account_key, date, timezone, dimension, dimension_value"

    private static let metricColumns = """
        total_tokens, input_tokens,
        output_tokens, cache_read_tokens, cache_write_tokens, reasoning_tokens, input_amount,
        output_amount, cache_read_amount, cache_write_amount, complete_amount, unpriced_tokens,
        unattributed_tokens, record_count, known_amount, unpriced_records
        """

    static var columns: String { "\(groupColumns), \(metricColumns)" }

    /// 先在 SQLite 中合并同日、同任务、同模型的用量分项，再展开四个维度，避免放大全部明细。
    static var aggregate: String { aggregate(predicate: "1") }

    static func aggregate(predicate: String, dateExpression: String? = nil) -> String { """
        WITH facts AS (
            SELECT \(dateExpression ?? dayExpression) AS day,
                u.account_id, u.thread_id, t.project_name, u.model, u.total_tokens,
                u.input_tokens, u.output_tokens, u.cache_read_tokens, u.cache_write_tokens, u.reasoning_tokens,
                u.input_amount, u.output_amount, u.cache_read_amount, u.cache_write_amount, u.amount,
                tokentick_known_amount(u.input_amount, u.output_amount, u.cache_read_amount, u.cache_write_amount, u.amount) AS known_amount
            FROM usage u LEFT JOIN threads t ON t.thread_id = u.thread_id
            WHERE (u.source = 'local' OR u.thread_id IS NOT NULL) AND (\(predicate))
        ), compact AS MATERIALIZED (
            SELECT day, account_id, thread_id, project_name, model,
                SUM(total_tokens) AS total_tokens, SUM(input_tokens) AS input_tokens, SUM(output_tokens) AS output_tokens,
                SUM(cache_read_tokens) AS cache_read_tokens, SUM(cache_write_tokens) AS cache_write_tokens,
                SUM(reasoning_tokens) AS reasoning_tokens, SUM(input_amount) AS input_amount,
                SUM(output_amount) AS output_amount, SUM(cache_read_amount) AS cache_read_amount,
                SUM(cache_write_amount) AS cache_write_amount, SUM(amount) AS complete_amount,
                SUM(CASE WHEN amount IS NULL THEN total_tokens ELSE 0 END) AS unpriced_tokens,
                SUM(CASE WHEN thread_id IS NULL THEN total_tokens ELSE 0 END) AS unattributed_tokens,
                COUNT(*) AS record_count, SUM(known_amount) AS known_amount,
                SUM(CASE WHEN amount IS NULL THEN 1 ELSE 0 END) AS unpriced_records
            FROM facts GROUP BY day, account_id, thread_id, project_name, model
        )
        SELECT CASE WHEN scope = 0 THEN 'all' WHEN account_id IS NULL THEN 'unknown' ELSE 'value:' || account_id END AS account_key,
            day AS date, :timezone AS timezone, dimension,
            CASE dimension WHEN 'all' THEN 'all'
                WHEN 'thread' THEN COALESCE('value:' || thread_id, 'unknown')
                WHEN 'project' THEN COALESCE('value:' || project_name, 'unknown')
                WHEN 'model' THEN COALESCE('value:' || model, 'unknown') END AS dimension_value,
            SUM(total_tokens), SUM(input_tokens), SUM(output_tokens), SUM(cache_read_tokens), SUM(cache_write_tokens),
            SUM(reasoning_tokens), SUM(input_amount), SUM(output_amount), SUM(cache_read_amount), SUM(cache_write_amount),
            SUM(complete_amount), SUM(unpriced_tokens), SUM(unattributed_tokens), SUM(record_count), SUM(known_amount), SUM(unpriced_records)
        FROM compact
        CROSS JOIN (SELECT 0 AS scope UNION ALL SELECT 1)
        CROSS JOIN (SELECT 'all' AS dimension UNION ALL SELECT 'thread' UNION ALL SELECT 'project' UNION ALL SELECT 'model')
        GROUP BY account_key, day, dimension, dimension_value
        """
    }
}
