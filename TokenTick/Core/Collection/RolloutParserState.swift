import Foundation

struct RolloutParserState: Codable {
    // 解析状态可丢弃重建；版本变化只触发重扫，不改写事实。
    static let currentVersion = 7
    var version = currentVersion
    var session: RolloutEvent.Session?
    var turnID: String?
    var model: String?
    var serviceTier: String?
    var reasoningEffort: String?
    var contextModel: String?
    var settings: UsageContextEvidence?
    var activeSettings: UsageContextEvidence?
    var modelSource: UsageContextEvidence?
    var serviceTierSource: UsageContextEvidence?
    var turnStartedLine: Int?
    var turnStartedAt: String?
    var modelCandidates: [String]?
    var cumulative: TokenUsage?
    var fallbackCumulative: TokenUsage?
    var fallbackUsage: TokenUsage?
    var fallbackTurnID: String?
    var recordUsage: TokenUsage?
    var recordTurnID: String?
    var recordResponseID: String?
    var inheritedEvents = 0
}

struct UsageContextEvidence: Codable {
    let eventType: String
    let fileName: String
    let rolloutID: String
    let line: Int
    let ordinal: UInt64?
    let threadID: String?
    let turnID: String?
    let model: String?
    let serviceTier: String?
    var provider: String? = nil
}

struct UsageEvidence: Codable {
    let fileName: String
    let timestamp: String
    let ordinal: UInt64?
    let eventType: String
    let serviceTier: String?
    let cumulative: TokenUsage
    let record: RolloutEvent.Record?
    var reasoningEffort: String? = nil
    var modelContextWindow: Int64? = nil
    var modelSource: UsageContextEvidence? = nil
    var serviceTierSource: UsageContextEvidence? = nil
    var threadSettings: UsageContextEvidence? = nil
    var turnStartedLine: Int? = nil
    var turnStartedAt: String? = nil
    var modelCandidates: [String]? = nil
}

struct CollectedUsage {
    let responseID: String?
    let legacyCumulative: TokenUsage?
    let threadID: String
    let turnID: String?
    let timestamp: Date
    let model: String?
    let tokens: TokenUsage
    let rolloutID: String
    let line: Int
    let evidence: UsageEvidence
}
