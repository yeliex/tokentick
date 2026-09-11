import Foundation
import GRDB

public struct UsageSummary: Codable, Sendable, Equatable {
    public let group: String?
    public let records: Int
    public let totalTokens: Int64
    public let inputTokens: Int64?
    public let outputTokens: Int64?
    public let cachedInputTokens: Int64?
    public let cacheWriteInputTokens: Int64?
    public let reasoningOutputTokens: Int64?
    public let knownAmountNanoUSD: Int64?
    public let inputAmountNanoUSD: Int64?
    public let outputAmountNanoUSD: Int64?
    public let cacheReadAmountNanoUSD: Int64?
    public let cacheWriteAmountNanoUSD: Int64?
    public let completeAmountNanoUSD: Int64?
    public let unpricedTokens: Int64
    public let unpricedRecords: Int
    public let unattributedTokens: Int64

    private enum CodingKeys: String, CodingKey {
        case group, records, totalTokens, inputTokens, outputTokens, cachedInputTokens
        case cacheWriteInputTokens, reasoningOutputTokens, knownAmountNanoUSD, unpricedTokens
        case inputAmountNanoUSD, outputAmountNanoUSD, cacheReadAmountNanoUSD, cacheWriteAmountNanoUSD
        case completeAmountNanoUSD, unpricedRecords, unattributedTokens
    }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(group, forKey: .group)
        try values.encode(records, forKey: .records)
        try values.encode(totalTokens, forKey: .totalTokens)
        try values.encode(inputTokens, forKey: .inputTokens)
        try values.encode(outputTokens, forKey: .outputTokens)
        try values.encode(cachedInputTokens, forKey: .cachedInputTokens)
        try values.encode(cacheWriteInputTokens, forKey: .cacheWriteInputTokens)
        try values.encode(reasoningOutputTokens, forKey: .reasoningOutputTokens)
        try values.encode(knownAmountNanoUSD, forKey: .knownAmountNanoUSD)
        try values.encode(inputAmountNanoUSD, forKey: .inputAmountNanoUSD)
        try values.encode(outputAmountNanoUSD, forKey: .outputAmountNanoUSD)
        try values.encode(cacheReadAmountNanoUSD, forKey: .cacheReadAmountNanoUSD)
        try values.encode(cacheWriteAmountNanoUSD, forKey: .cacheWriteAmountNanoUSD)
        try values.encode(completeAmountNanoUSD, forKey: .completeAmountNanoUSD)
        try values.encode(unpricedTokens, forKey: .unpricedTokens)
        try values.encode(unpricedRecords, forKey: .unpricedRecords)
        try values.encode(unattributedTokens, forKey: .unattributedTokens)
    }
}

extension UsageSummary {
    init(row: Row) {
        self.init(group: row["group_value"], records: row["records"], totalTokens: row["total_tokens"],
            inputTokens: row["input_tokens"], outputTokens: row["output_tokens"],
            cachedInputTokens: row["cache_read_tokens"], cacheWriteInputTokens: row["cache_write_tokens"],
            reasoningOutputTokens: row["reasoning_tokens"], knownAmountNanoUSD: row["known_amount"],
            inputAmountNanoUSD: row["input_amount"], outputAmountNanoUSD: row["output_amount"],
            cacheReadAmountNanoUSD: row["cache_read_amount"], cacheWriteAmountNanoUSD: row["cache_write_amount"],
            completeAmountNanoUSD: row["complete_amount"], unpricedTokens: row["unpriced_tokens"],
            unpricedRecords: row["unpriced_records"], unattributedTokens: row["unattributed_tokens"])
    }
}
