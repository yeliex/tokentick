import Foundation
import GRDB

/// nil 代表该维度的未知归属，不等同于不筛选。
public enum UsageRecordScope: Sendable, Equatable {
    case all, thread(String?), project(String?), model(String?), day(String?)
}

public struct UsageRecord: Encodable, Sendable, Identifiable, Equatable {
    public let id: Int64
    public let accountID: String?
    public let threadID: String?
    public let title: String?
    public let projectName: String?
    public let turnID: String?
    public let responseID: String?
    public let sourceOrdinal: Int64?
    public let hour: Int?
    public let minute: Int?
    public let occurredAt: Double?
    public let usageDate: String?
    public let statisticalDate: String?
    public let model: String?
    public let tier: String?
    public var isFast: Bool? { CodexServiceTier.isFast(tier) }
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
    public let reasoningEffort: String?
    public let pricingTier: String?
    public let pricingSource: String?
    public var pricingIsFast: Bool { (pricingTier ?? tier) == "fast" }

    private enum CodingKeys: String, CodingKey {
        case id, accountID, threadID, title, projectName, turnID, responseID, sourceOrdinal, hour, minute
        case occurredAt, usageDate, statisticalDate, model
        case tier, isLongContext, inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens
        case reasoningTokens, totalTokens, inputPrice, outputPrice, cacheReadPrice, cacheWritePrice
        case inputAmountNanoUSD, outputAmountNanoUSD, cacheReadAmountNanoUSD, cacheWriteAmountNanoUSD, amountNanoUSD, knownAmountNanoUSD
        case source, rolloutID, sourceLine, fileName, lastKnownPath, reasoningEffort, pricingTier, pricingSource
    }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(accountID, forKey: .accountID)
        try values.encode(threadID, forKey: .threadID)
        try values.encode(title, forKey: .title)
        try values.encode(projectName, forKey: .projectName)
        try values.encode(turnID, forKey: .turnID)
        try values.encode(responseID, forKey: .responseID)
        try values.encode(sourceOrdinal, forKey: .sourceOrdinal)
        try values.encode(hour, forKey: .hour)
        try values.encode(minute, forKey: .minute)
        try values.encode(occurredAt, forKey: .occurredAt)
        try values.encode(usageDate, forKey: .usageDate)
        try values.encode(statisticalDate, forKey: .statisticalDate)
        try values.encode(model, forKey: .model)
        try values.encode(tier, forKey: .tier)
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
        try values.encode(reasoningEffort, forKey: .reasoningEffort)
        try values.encode(pricingTier, forKey: .pricingTier)
        try values.encode(pricingSource, forKey: .pricingSource)
    }
}

public struct UsageRecordPage: Encodable, Sendable {
    public let timezone: String
    public let rows: [UsageRecord]
    public let hasMore: Bool
    public let granularity = "usage_event"
    public let amountUnit = "nanoUSD"
    public let priceUnit = "USD_per_million_tokens"
}

extension UsageRecord {
    init(row: Row) {
        self.init(id: row["id"], accountID: row["account_id"], threadID: row["thread_id"],
            title: row["title"], projectName: row["project_name"], turnID: row["turn_id"],
            responseID: row["response_id"], sourceOrdinal: row["source_ordinal"], hour: row["hour"], minute: row["minute"],
            occurredAt: row["occurred_at"],
            usageDate: row["usage_date"], statisticalDate: row["statistical_date"], model: row["model"],
            tier: row["tier"], isLongContext: row["is_long_context"], inputTokens: row["input_tokens"],
            outputTokens: row["output_tokens"], cacheReadTokens: row["cache_read_tokens"],
            cacheWriteTokens: row["cache_write_tokens"], reasoningTokens: row["reasoning_tokens"],
            totalTokens: row["total_tokens"], inputPrice: row["input_price"], outputPrice: row["output_price"],
            cacheReadPrice: row["cache_read_price"], cacheWritePrice: row["cache_write_price"],
            inputAmountNanoUSD: row["input_amount"], outputAmountNanoUSD: row["output_amount"],
            cacheReadAmountNanoUSD: row["cache_read_amount"], cacheWriteAmountNanoUSD: row["cache_write_amount"],
            amountNanoUSD: row["amount"], knownAmountNanoUSD: row["known_amount"], source: row["source"],
            rolloutID: row["rollout_id"], sourceLine: row["source_line"], fileName: row["file_name"],
            lastKnownPath: row["current_path"], reasoningEffort: row["reasoning_effort"], pricingTier: row["pricing_tier"], pricingSource: row["pricing_source"])
    }
}
