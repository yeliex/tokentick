import Foundation

public struct TokenUsage: Codable, Equatable, Sendable {
    public let inputTokens: Int64
    public let outputTokens: Int64
    public let cachedInputTokens: Int64?
    public let cacheWriteInputTokens: Int64?
    public let reasoningOutputTokens: Int64?
    public let totalTokens: Int64

    init(inputTokens: Int64, outputTokens: Int64, cachedInputTokens: Int64?, cacheWriteInputTokens: Int64?,
         reasoningOutputTokens: Int64?, totalTokens: Int64) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheWriteInputTokens = cacheWriteInputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.totalTokens = totalTokens
    }

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cachedInputTokens = "cached_input_tokens"
        case cacheWriteInputTokens = "cache_write_input_tokens"
        case reasoningOutputTokens = "reasoning_output_tokens"
        case totalTokens = "total_tokens"
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens = try values.decode(Int64.self, forKey: .inputTokens)
        outputTokens = try values.decode(Int64.self, forKey: .outputTokens)
        cachedInputTokens = try values.decodeIfPresent(Int64.self, forKey: .cachedInputTokens)
        cacheWriteInputTokens = try values.decodeIfPresent(Int64.self, forKey: .cacheWriteInputTokens)
        reasoningOutputTokens = try values.decodeIfPresent(Int64.self, forKey: .reasoningOutputTokens)
        totalTokens = try values.decode(Int64.self, forKey: .totalTokens)
        let counters = [inputTokens, outputTokens, cachedInputTokens, cacheWriteInputTokens, reasoningOutputTokens, totalTokens]
        guard counters.compactMap({ $0 }).allSatisfy({ $0 >= 0 }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: String(localized: "Token counts cannot be negative.", bundle: .module)))
        }
    }
}
