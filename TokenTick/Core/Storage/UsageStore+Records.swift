import Foundation
import GRDB

/// nil 代表该维度的未知归属，不等同于不筛选。
public enum UsageRecordScope: Sendable, Equatable {
    case all, thread(String?), project(String?), model(String?), day(String?)
}

public struct UsageRecord: Encodable, Sendable, Identifiable {
    public let id: Int64
    public let accountID: String?
    public let threadID: String?
    public let title: String?
    public let projectName: String?
    public let turnID: String?
    public let requestID: String?
    public let responseID: String?
    public let occurredAt: Double?
    public let usageDate: String?
    public let statisticalDate: String?
    public let model: String?
    public let isFast: Bool?
    public let isLongContext: Bool?
    public let inputTokens: Int64?
    public let outputTokens: Int64?
    public let cacheReadTokens: Int64?
    public let cacheWriteTokens: Int64?
    public let reasoningTokens: Int64?
    public let totalTokens: Int64
    public let inputPrice: String?
    public let outputPrice: String?
    public let cacheReadPrice: String?
    public let cacheWritePrice: String?
    public let inputAmountNanoUSD: Int64?
    public let outputAmountNanoUSD: Int64?
    public let cacheReadAmountNanoUSD: Int64?
    public let cacheWriteAmountNanoUSD: Int64?
    public let amountNanoUSD: Int64?
    public let knownAmountNanoUSD: Int64?
    public let source: String
    public let rolloutID: String?
    public let sourceLine: Int?
    public let fileName: String?
    public let lastKnownPath: String?
    public let evidenceJSON: String

    public var pricingIsFast: Bool {
        if let isFast { return isFast }
        let proof = (try? JSONSerialization.jsonObject(with: Data(evidenceJSON.utf8))) as? [String: Any]
        return (proof?["pricingMode"] as? [String: Any])?["isFast"] as? Bool ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case id, accountID, threadID, title, projectName, turnID
        case requestID, responseID, occurredAt, usageDate, statisticalDate, model
        case isFast, isLongContext, inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens
        case reasoningTokens, totalTokens, inputPrice, outputPrice, cacheReadPrice, cacheWritePrice
        case inputAmountNanoUSD, outputAmountNanoUSD, cacheReadAmountNanoUSD, cacheWriteAmountNanoUSD, amountNanoUSD, knownAmountNanoUSD
        case source, rolloutID, sourceLine, fileName, lastKnownPath, evidenceJSON
    }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(accountID, forKey: .accountID)
        try values.encode(threadID, forKey: .threadID)
        try values.encode(title, forKey: .title)
        try values.encode(projectName, forKey: .projectName)
        try values.encode(turnID, forKey: .turnID)
        try values.encode(requestID, forKey: .requestID)
        try values.encode(responseID, forKey: .responseID)
        try values.encode(occurredAt, forKey: .occurredAt)
        try values.encode(usageDate, forKey: .usageDate)
        try values.encode(statisticalDate, forKey: .statisticalDate)
        try values.encode(model, forKey: .model)
        try values.encode(isFast, forKey: .isFast)
        try values.encode(isLongContext, forKey: .isLongContext)
        try values.encode(inputTokens, forKey: .inputTokens)
        try values.encode(outputTokens, forKey: .outputTokens)
        try values.encode(cacheReadTokens, forKey: .cacheReadTokens)
        try values.encode(cacheWriteTokens, forKey: .cacheWriteTokens)
        try values.encode(reasoningTokens, forKey: .reasoningTokens)
        try values.encode(totalTokens, forKey: .totalTokens)
        try values.encode(inputPrice, forKey: .inputPrice)
        try values.encode(outputPrice, forKey: .outputPrice)
        try values.encode(cacheReadPrice, forKey: .cacheReadPrice)
        try values.encode(cacheWritePrice, forKey: .cacheWritePrice)
        try values.encode(inputAmountNanoUSD, forKey: .inputAmountNanoUSD)
        try values.encode(outputAmountNanoUSD, forKey: .outputAmountNanoUSD)
        try values.encode(cacheReadAmountNanoUSD, forKey: .cacheReadAmountNanoUSD)
        try values.encode(cacheWriteAmountNanoUSD, forKey: .cacheWriteAmountNanoUSD)
        try values.encode(amountNanoUSD, forKey: .amountNanoUSD)
        try values.encode(knownAmountNanoUSD, forKey: .knownAmountNanoUSD)
        try values.encode(source, forKey: .source)
        try values.encode(rolloutID, forKey: .rolloutID)
        try values.encode(sourceLine, forKey: .sourceLine)
        try values.encode(fileName, forKey: .fileName)
        try values.encode(lastKnownPath, forKey: .lastKnownPath)
        try values.encode(evidenceJSON, forKey: .evidenceJSON)
    }
}

public struct UsageRecordPage: Encodable, Sendable {
    public let timezone: String
    public let rows: [UsageRecord]
    public let hasMore: Bool
    public let amountUnit = "nanoUSD"
    public let priceUnit = "USD_per_million_tokens"
}

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
                \(filters.isEmpty ? "" : "WHERE " + filters.joined(separator: " AND "))
                ORDER BY \(order) LIMIT :limit OFFSET :offset
                """, arguments: arguments)
            return UsageRecordPage(timezone: timezone.identifier, rows: rows.prefix(query.limit).map { row in
                UsageRecord(id: row["id"], accountID: row["account_id"], threadID: row["thread_id"],
                    title: row["title"], projectName: row["project_name"], turnID: row["turn_id"],
                    requestID: row["request_id"], responseID: row["response_id"], occurredAt: row["occurred_at"],
                    usageDate: row["usage_date"], statisticalDate: row["statistical_date"], model: row["model"],
                    isFast: row["is_fast"], isLongContext: row["is_long_context"], inputTokens: row["input_tokens"],
                    outputTokens: row["output_tokens"], cacheReadTokens: row["cache_read_tokens"],
                    cacheWriteTokens: row["cache_write_tokens"], reasoningTokens: row["reasoning_tokens"],
                    totalTokens: row["total_tokens"], inputPrice: row["input_price"], outputPrice: row["output_price"],
                    cacheReadPrice: row["cache_read_price"], cacheWritePrice: row["cache_write_price"],
                    inputAmountNanoUSD: row["input_amount"], outputAmountNanoUSD: row["output_amount"],
                    cacheReadAmountNanoUSD: row["cache_read_amount"], cacheWriteAmountNanoUSD: row["cache_write_amount"],
                    amountNanoUSD: row["amount"], knownAmountNanoUSD: row["known_amount"], source: row["source"],
                    rolloutID: row["rollout_id"], sourceLine: row["source_line"], fileName: row["file_name"],
                    lastKnownPath: row["current_path"], evidenceJSON: row["evidence_json"])
            }, hasMore: rows.count > query.limit)
        }
    }
}
