import Foundation

struct RolloutEvent: Decodable {
    let timestamp: String?
    let ordinal: UInt64?
    let payload: Payload

    enum Payload {
        case session(Session), turn(Turn), count(Count), record(Record), other
    }
    struct Session: Codable {
        let id: String
        let timestamp: String?
        let cwd: String?
        let forked_from_id: String?
        let forked_from_ordinal_exclusive: UInt64?
        let subagent_history_start_ordinal: UInt64?
        let history_mode: String?
        let history_base: HistoryBase?
        struct HistoryBase: Codable {
            let thread_id: String
            let end_ordinal_exclusive: UInt64
            let end_byte_offset: UInt64
        }
    }
    struct Turn: Decodable {
        let turn_id: String?
        let model: String?
        let service_tier: String?
    }
    struct Count: Decodable {
        let info: Info?
        struct Info: Codable, Equatable {
            let total_token_usage: TokenUsage
            let last_token_usage: TokenUsage
            let model_context_window: Int64?
        }
    }
    struct Record: Codable {
        let thread_id: String
        let turn_id: String
        let session_id: String?
        let root_turn_id: String?
        let response_id: String
        let usage: TokenUsage
        let turn_token_usage: TokenUsage?
        let thread_token_usage: TokenUsage
    }
    private enum CodingKeys: String, CodingKey { case timestamp, ordinal, type, payload }
    private struct EventType: Decodable { let type: String }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try values.decodeIfPresent(String.self, forKey: .timestamp)
        ordinal = try values.decodeIfPresent(UInt64.self, forKey: .ordinal)
        switch try values.decode(String.self, forKey: .type) {
        case "session_meta": payload = .session(try values.decode(Session.self, forKey: .payload))
        case "turn_context": payload = .turn(try values.decode(Turn.self, forKey: .payload))
        case "token_usage_record": payload = .record(try values.decode(Record.self, forKey: .payload))
        case "event_msg":
            let eventType = try values.decode(EventType.self, forKey: .payload)
            payload = eventType.type == "token_count" ? .count(try values.decode(Count.self, forKey: .payload)) : .other
        default: payload = .other
        }
    }
}

struct RolloutParserState: Codable {
    // 解析状态可丢弃重建；版本变化只触发重扫，不改写事实。
    static let currentVersion = 1
    var version = currentVersion
    var session: RolloutEvent.Session?
    var turnID: String?
    var model: String?
    var serviceTier: String?
    var cumulative: TokenUsage?
    var fallbackKey: String?
    var fallbackUsage: TokenUsage?
    var fallbackTurnID: String?
    var recordCumulative: TokenUsage?
    var recordUsage: TokenUsage?
    var inheritedEvents = 0
}

struct UsageEvidence: Codable {
    let fileName: String
    let timestamp: String
    let ordinal: UInt64?
    let eventType: String
    let serviceTier: String?
    let cumulative: TokenUsage
    let record: RolloutEvent.Record?
    var legacyKey: String? = nil
    var modelContextWindow: Int64? = nil
}

struct CollectedUsage {
    let dedupKey: String
    let replacesKey: String?
    let threadID: String
    let turnID: String?
    let responseID: String?
    let timestamp: Date
    let model: String?
    let isFast: Bool?
    let tokens: TokenUsage
    let rolloutID: String
    let line: Int
    let evidence: UsageEvidence
}

enum CodexServiceTier {
    static func isFast(_ value: String?) -> Bool? {
        switch value {
        case "priority", "fast": true
        case "default", "standard": false
        default: nil
        }
    }
}
