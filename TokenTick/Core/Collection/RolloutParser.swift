import CryptoKit
import Foundation

struct RolloutParser {
    enum ParseError: Error, LocalizedError {
        case missingSession, mismatchedThread, missingTimestamp, ambiguousFork
        var errorDescription: String? {
            switch self {
            case .missingSession: "用量事件前缺少 session_meta。"
            case .mismatchedThread: "日志的 session_meta 与文件名中的对话 ID 不一致。"
            case .missingTimestamp: "用量事件缺少有效时间。"
            case .ambiguousFork: "fork 日志缺少可验证的继承边界，暂停入库以避免重复统计。"
            }
        }
    }
    var state: RolloutParserState
    let identity: RolloutIdentity
    private let decoder = JSONDecoder()

    mutating func consume(_ data: Data, line: Int) throws -> CollectedUsage? {
        if data.allSatisfy({ $0 == 32 || $0 == 13 || $0 == 9 }) { return nil }
        let event = try decoder.decode(RolloutEvent.self, from: data)
        switch event.payload {
        case .session(let session):
            if session.id.lowercased() != identity.threadID.uuidString.lowercased() {
                if let owner = state.session, try isInherited(event, session: owner) { return nil }
                throw ParseError.mismatchedThread
            }
            state.session = session
            return nil
        case .turn(let turn):
            state.turnID = turn.turn_id
            state.model = turn.model
            state.serviceTier = turn.service_tier
            return nil
        case .other: return nil
        case .count(let count):
            guard let info = count.info else { return nil }
            guard let session = state.session else { throw ParseError.missingSession }
            let inherited = try isInherited(event, session: session)
            let previous = state.cumulative
            state.cumulative = info.total_token_usage
            if inherited {
                state.inheritedEvents += 1
                state.fallbackKey = nil
                state.fallbackUsage = nil
                return nil
            }
            let usage = info.last_token_usage
            if state.recordCumulative == info.total_token_usage && state.recordUsage == usage { return nil }
            state.recordCumulative = nil
            state.recordUsage = nil
            guard previous != info.total_token_usage, usage.totalTokens > 0 else { return nil }
            // Codex 会用全零分项发布 context-window 饱和占位；它不是一次真实请求。
            guard usage.inputTokens > 0 || usage.outputTokens > 0 else { return nil }
            if let previous, info.total_token_usage.totalTokens < previous.totalTokens,
               info.total_token_usage != usage {
                state.fallbackKey = nil
                state.fallbackUsage = nil
                return nil
            }
            var evidence = try evidence(event, type: "token_count", cumulative: info.total_token_usage)
            evidence.modelContextWindow = info.model_context_window
            // 相同事实会随归档、fork 或 revert 被复制；路径、行号和 ordinal 都不能充当请求 ID。
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let signature = LegacySignature(thread: session.id.lowercased(), turn: state.turnID,
                                            timestamp: evidence.timestamp, cumulative: info.total_token_usage, usage: usage)
            let key = "legacy:" + SHA256.hash(data: try encoder.encode(signature)).map { String(format: "%02x", $0) }.joined()
            state.fallbackKey = key
            state.fallbackUsage = usage
            state.fallbackTurnID = state.turnID
            return try makeUsage(key: key, replaces: nil, event: event, usage: usage,
                                 thread: session.id, turn: state.turnID, response: nil, line: line, evidence: evidence)
        case .record(let record):
            guard let session = state.session else { throw ParseError.missingSession }
            if try isInherited(event, session: session) || record.thread_id.lowercased() != session.id.lowercased() {
                state.inheritedEvents += 1
                state.cumulative = record.thread_token_usage
                return nil
            }
            let replaces = state.cumulative == record.thread_token_usage && state.fallbackUsage == record.usage && state.fallbackTurnID == record.turn_id
                ? state.fallbackKey : nil
            state.recordCumulative = record.thread_token_usage
            state.recordUsage = record.usage
            state.cumulative = record.thread_token_usage
            state.fallbackKey = nil
            state.fallbackUsage = nil
            let evidence = try evidence(event, type: "token_usage_record", cumulative: record.thread_token_usage, record: record)
            return try makeUsage(key: "response:" + record.response_id, replaces: replaces, event: event,
                                 usage: record.usage, thread: record.thread_id, turn: record.turn_id,
                                 response: record.response_id, line: line, evidence: evidence)
        }
    }

    private func isInherited(_ event: RolloutEvent, session: RolloutEvent.Session) throws -> Bool {
        let boundary = session.subagent_history_start_ordinal ?? session.forked_from_ordinal_exclusive
        if let boundary, let ordinal = event.ordinal { return ordinal < boundary }
        guard session.forked_from_id != nil else { return false }
        // paginated history_base 引用外部前缀，本文件只保存后续事件。
        if session.history_mode == "paginated", let base = session.history_base,
           let ordinal = event.ordinal, ordinal >= base.end_ordinal_exclusive { return false }
        if let created = session.timestamp.flatMap(Self.parseDate), let occurred = event.timestamp.flatMap(Self.parseDate) {
            return occurred < created
        }
        throw ParseError.ambiguousFork
    }

    private func evidence(_ event: RolloutEvent, type: String, cumulative: TokenUsage,
                          record: RolloutEvent.Record? = nil) throws -> UsageEvidence {
        guard let timestamp = event.timestamp, Self.parseDate(timestamp) != nil else { throw ParseError.missingTimestamp }
        return UsageEvidence(fileName: identity.fileName, timestamp: timestamp, ordinal: event.ordinal,
                             eventType: type, serviceTier: state.serviceTier, cumulative: cumulative, record: record)
    }

    private func makeUsage(key: String, replaces: String?, event: RolloutEvent, usage: TokenUsage,
                           thread: String, turn: String?, response: String?, line: Int,
                           evidence: UsageEvidence) throws -> CollectedUsage {
        guard let timestamp = Self.parseDate(evidence.timestamp) else { throw ParseError.missingTimestamp }
        let fast = CodexServiceTier.isFast(state.serviceTier)
        return CollectedUsage(dedupKey: key, replacesKey: replaces, threadID: thread.lowercased(),
                              turnID: turn, responseID: response, timestamp: timestamp,
                              model: turn == state.turnID ? state.model : nil, isFast: turn == state.turnID ? fast : nil, tokens: usage,
                              rolloutID: identity.rolloutID.uuidString.lowercased(), line: line, evidence: evidence)
    }

    static func parseDate(_ text: String) -> Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text))
            ?? (try? Date.ISO8601FormatStyle().parse(text))
    }

    private struct LegacySignature: Encodable {
        let thread: String
        let turn: String?
        let timestamp: String
        let cumulative: TokenUsage
        let usage: TokenUsage
    }
}
