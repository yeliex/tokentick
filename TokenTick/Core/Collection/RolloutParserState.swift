import Foundation

struct RolloutParserState: Codable {
    // 解析状态可丢弃重建；版本变化只触发重扫，不改写事实。
    static let currentVersion = 9
    var version = currentVersion
    var weeklyWindows: [WeeklyCycleCalculator.Window]?
    var session: RolloutEvent.Session?
    var turnID: String?
    var model: String?
    var serviceTier: String?
    var reasoningEffort: String?
    var contextModel: String?
    var settings: ParserSettings?
    var turnStartedAt: String?
    var cumulative: TokenUsage?
    var fallbackCumulative: TokenUsage?
    var fallbackUsage: TokenUsage?
    var fallbackTurnID: String?
    var recordUsage: TokenUsage?
    var recordTurnID: String?
    var recordResponseID: String?
}

struct ParserSettings: Codable {
    let model: String?
    let serviceTier: String?
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
    var turnStartedAt: String? = nil
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
