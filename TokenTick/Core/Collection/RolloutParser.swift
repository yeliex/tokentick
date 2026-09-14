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
    var currentLimits: CurrentLimitSnapshot?

    mutating func consume(_ data: Data, line: Int) throws -> CollectedUsage? {
        currentLimits = nil
        if data.allSatisfy({ $0 == 32 || $0 == 13 || $0 == 9 }) { return nil }
        let event = try decoder.decode(RolloutEvent.self, from: data)
        switch event.payload {
        case .session(var session):
            if session.id.lowercased() != identity.threadID.uuidString.lowercased() {
                if let owner = state.session, try isInherited(event, session: owner) { return nil }
                throw ParseError.mismatchedThread
            }
            if session.timestamp == nil { session.timestamp = event.timestamp }
            state.session = session
            return nil
        case .turn(let turn):
            let sameTurn = turn.turn_id != nil && turn.turn_id == state.turnID
            let source = UsageContextEvidence(eventType: "turn_context", fileName: identity.fileName,
                rolloutID: identity.rolloutID.uuidString.lowercased(), line: line, ordinal: event.ordinal,
                threadID: state.session?.id, turnID: turn.turn_id, model: turn.model, serviceTier: turn.service_tier)
            state.contextModel = turn.model
            state.reasoningEffort = turn.effort
            if !sameTurn {
                state.serviceTier = nil
                state.serviceTierSource = nil
                state.activeSettings = nil
                state.turnStartedLine = nil
                state.turnStartedAt = event.timestamp
            }
            state.turnID = turn.turn_id
            state.model = turn.model
            state.modelSource = turn.model == nil ? nil : source
            state.modelCandidates = nil
            if turn.hasServiceTier {
                state.serviceTier = turn.service_tier
                state.serviceTierSource = source
            }
            return nil
        case .settings(let settings):
            guard let session = state.session,
                  settings.thread_id == nil || settings.thread_id?.lowercased() == session.id.lowercased(),
                  try !isInherited(event, session: session) else { return nil }
            // 持久设置的更改不直接改变正在执行的轮次，等下一次开始事件绑定。
            state.settings = UsageContextEvidence(eventType: "thread_settings_applied", fileName: identity.fileName,
                rolloutID: identity.rolloutID.uuidString.lowercased(), line: line, ordinal: event.ordinal,
                threadID: settings.thread_id, turnID: nil, model: settings.thread_settings.model,
                serviceTier: settings.thread_settings.service_tier, provider: settings.thread_settings.model_provider_id)
            return nil
        case .started(let started):
            guard let session = state.session, try !isInherited(event, session: session) else { return nil }
            state.turnID = started.turn_id
            state.reasoningEffort = nil
            state.activeSettings = state.settings
            state.turnStartedLine = line
            state.turnStartedAt = event.timestamp
            state.serviceTier = state.settings?.serviceTier
            state.serviceTierSource = state.settings
            let model = state.settings?.model
            // 前置压缩可能使用上一模型；两者不同时，直到本轮上下文出现前都不能任选一个。
            let ambiguous = model != nil && (state.contextModel.map { $0 != model } ?? (session.forked_from_id != nil))
            state.model = ambiguous ? nil : model
            state.modelSource = state.model == nil ? nil : state.settings
            state.modelCandidates = ambiguous ? [state.contextModel, model].compactMap { $0 } : nil
            return nil
        case .other: return nil
        case .count(let count):
            if let raw = count.rate_limits, let session = state.session,
               let timestamp = event.timestamp.flatMap(DateParsing.parseTimestamp) {
                currentLimits = try CurrentLimitSnapshot.log(raw: raw, observedAt: timestamp.timeIntervalSince1970,
                    threadID: session.id, fileName: identity.fileName, line: line)
                currentLimits?.turnID = state.turnID
                if try isInherited(event, session: session) { currentLimits?.historyExclusion = "inherited" }
                else if session.forked_from_id != nil, let created = session.timestamp.flatMap(DateParsing.parseTimestamp), timestamp <= created {
                    currentLimits?.historyExclusion = "fork_replay"
                }
            }
            guard let info = count.info else { return nil }
            guard let session = state.session else { throw ParseError.missingSession }
            let inherited = try isInherited(event, session: session)
            let previous = state.cumulative
            state.cumulative = info.total_token_usage
            if inherited {
                state.inheritedEvents += 1
                state.fallbackCumulative = nil
                state.fallbackUsage = nil
                return nil
            }
            let usage = info.last_token_usage
            var evidence = try evidence(event, type: "token_count", cumulative: info.total_token_usage)
            evidence.modelContextWindow = info.model_context_window
            // 新旧用量流可能采用不同的任务累计基线。新格式之后的同轮次、同分项报告只计一次。
            if state.recordTurnID == state.turnID && state.recordUsage == usage, let response = state.recordResponseID {
                state.recordUsage = nil
                return try makeUsage(responseID: response, legacy: info.total_token_usage, usage: usage,
                    thread: session.id, turn: state.turnID, line: line, evidence: evidence)
            }
            state.recordUsage = nil
            guard previous != info.total_token_usage, usage.totalTokens > 0 else { return nil }
            // Codex 会用全零分项发布 context-window 饱和占位；它不是一次真实请求。
            guard usage.inputTokens > 0 || usage.outputTokens > 0 else { return nil }
            if let previous, info.total_token_usage.totalTokens < previous.totalTokens,
               info.total_token_usage != usage {
                state.fallbackCumulative = nil
                state.fallbackUsage = nil
                return nil
            }
            // 相同事实会随归档、fork 或 revert 被复制；路径、行号和 ordinal 都不能充当请求 ID。
            state.fallbackCumulative = info.total_token_usage
            state.fallbackUsage = usage
            state.fallbackTurnID = state.turnID
            return try makeUsage(responseID: nil, legacy: info.total_token_usage, usage: usage,
                                 thread: session.id, turn: state.turnID, line: line, evidence: evidence)
        case .record(let record):
            guard let session = state.session else { throw ParseError.missingSession }
            if try isInherited(event, session: session) || record.thread_id.lowercased() != session.id.lowercased() {
                state.inheritedEvents += 1
                return nil
            }
            let replaces = state.cumulative == record.thread_token_usage && state.fallbackUsage == record.usage && state.fallbackTurnID == record.turn_id
                ? state.fallbackCumulative : nil
            state.recordUsage = record.usage
            state.recordTurnID = record.turn_id
            state.recordResponseID = record.response_id
            state.fallbackCumulative = nil
            state.fallbackUsage = nil
            let evidence = try evidence(event, type: "token_usage_record", cumulative: record.thread_token_usage, record: record)
            return try makeUsage(responseID: record.response_id, legacy: replaces,
                                 usage: record.usage, thread: record.thread_id, turn: record.turn_id,
                                 line: line, evidence: evidence)
        }
    }

    private func isInherited(_ event: RolloutEvent, session: RolloutEvent.Session) throws -> Bool {
        let boundary = session.subagent_history_start_ordinal ?? session.forked_from_ordinal_exclusive
        if let boundary, let ordinal = event.ordinal { return ordinal < boundary }
        guard session.forked_from_id != nil else { return false }
        // paginated history_base 引用外部前缀，本文件只保存后续事件。
        if session.history_mode == "paginated", let base = session.history_base,
           let ordinal = event.ordinal, ordinal >= base.end_ordinal_exclusive { return false }
        if let created = session.timestamp.flatMap(DateParsing.parseTimestamp), let occurred = event.timestamp.flatMap(DateParsing.parseTimestamp) {
            return occurred < created
        }
        throw ParseError.ambiguousFork
    }

    private func evidence(_ event: RolloutEvent, type: String, cumulative: TokenUsage,
                          record: RolloutEvent.Record? = nil) throws -> UsageEvidence {
        guard let timestamp = event.timestamp, DateParsing.parseTimestamp(timestamp) != nil else { throw ParseError.missingTimestamp }
        let sameTurn = record == nil || record?.turn_id == state.turnID
        return UsageEvidence(fileName: identity.fileName, timestamp: timestamp, ordinal: event.ordinal,
            eventType: type, serviceTier: sameTurn ? state.serviceTier : nil, cumulative: cumulative, record: record,
            reasoningEffort: sameTurn ? state.reasoningEffort : nil,
            modelSource: sameTurn ? state.modelSource : nil, serviceTierSource: sameTurn ? state.serviceTierSource : nil,
            threadSettings: sameTurn ? state.activeSettings : nil, turnStartedLine: sameTurn ? state.turnStartedLine : nil,
            turnStartedAt: sameTurn ? state.turnStartedAt : nil,
            modelCandidates: sameTurn ? state.modelCandidates : nil)
    }

    private func makeUsage(responseID: String?, legacy: TokenUsage?, usage: TokenUsage,
                           thread: String, turn: String?, line: Int,
                           evidence: UsageEvidence) throws -> CollectedUsage {
        guard let timestamp = DateParsing.parseTimestamp(evidence.timestamp) else { throw ParseError.missingTimestamp }
        return CollectedUsage(responseID: responseID, legacyCumulative: legacy, threadID: thread.lowercased(),
                              turnID: turn, timestamp: timestamp,
                              model: turn == state.turnID ? state.model : nil, tokens: usage,
                              rolloutID: identity.rolloutID.uuidString.lowercased(), line: line, evidence: evidence)
    }
}
