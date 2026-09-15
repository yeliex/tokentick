import Foundation
import GRDB

extension UsageStore {
    private struct ConflictingEvent: Error, LocalizedError {
        var errorDescription: String? { String(localized: "The usage event has conflicting identity or components. Records and the scan cursor were not advanced.", bundle: .module) }
    }

    /// 请求保留轮次归属与累计分项，混合日志格式按响应或完整累计值去重。
    static func collectTurns(_ usages: [CollectedUsage], session: RolloutEvent.Session?, db: Database) throws
        -> (inserted: Int, upgraded: Int, duplicates: Int) {
        var inserted = 0, upgraded = 0, duplicates = 0
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .gmt
        for usage in usages {
            let key = usage.turnID.map { "turn:" + $0 } ?? "unattributed:" + usage.threadID
            let created = session?.timestamp.flatMap(DateParsing.parseTimestamp)?.timeIntervalSince1970
            let time = usage.timestamp.timeIntervalSince1970
            let start = usage.evidence.turnStartedAt.flatMap(DateParsing.parseTimestamp)?.timeIntervalSince1970 ?? time
            if let owner = try Row.fetchOne(db, sql: "SELECT thread_id,source_created_at FROM usage WHERE turn_key=? LIMIT 1", arguments: [key]),
               let thread: String = owner["thread_id"], thread != usage.threadID {
                guard let created, let old: Double = owner["source_created_at"], created < old else {
                    duplicates += 1; continue
                }
                // 原始任务晚到时替换 fork 副本，不能同时计入两份历史。
                try db.execute(sql: "DELETE FROM usage WHERE turn_key=?", arguments: [key])
            }
            let tier = CodexServiceTier.normalized(usage.evidence.serviceTier)
            var matches: [Int64: Row] = [:]
            if let response = usage.responseID,
               let row = try Row.fetchOne(db, sql: "SELECT * FROM usage WHERE turn_key=? AND response_id=?", arguments: [key,response]) {
                matches[row["id"]] = row
            }
            if let cumulative = usage.legacyCumulative {
                let rows = try Row.fetchAll(db, sql: """
                    SELECT * FROM usage WHERE turn_key=? AND legacy_total=?
                        AND legacy_input IS ? AND legacy_output IS ? AND legacy_cache_read IS ?
                        AND legacy_cache_write IS ? AND legacy_reasoning IS ?
                        AND (? IS NULL OR response_id IS NULL OR response_id=?)
                    """, arguments: [key,cumulative.totalTokens,cumulative.inputTokens,cumulative.outputTokens,
                        cumulative.cachedInputTokens,cumulative.cacheWriteInputTokens,cumulative.reasoningOutputTokens,
                        usage.responseID,usage.responseID])
                for row in rows { matches[row["id"]] = row }
            }
            let ordered = matches.values.sorted { ($0["id"] as Int64) < ($1["id"] as Int64) }
            for row in ordered {
                let tokens = TokenUsage(inputTokens: row["input_tokens"], outputTokens: row["output_tokens"],
                    cachedInputTokens: row["cache_read_tokens"], cacheWriteInputTokens: row["cache_write_tokens"],
                    reasoningOutputTokens: row["reasoning_tokens"], totalTokens: row["total_tokens"])
                guard tokens == usage.tokens else { throw ConflictingEvent() }
                if let value: String = row["response_id"], let incoming = usage.responseID, value != incoming { throw ConflictingEvent() }
                if let value: String = row["model"], let incoming = usage.model, value != incoming { throw ConflictingEvent() }
                if let value: String = row["tier"], let tier, value != tier { throw ConflictingEvent() }
            }
            let existing = ordered.first { ($0["response_id"] as String?) != nil } ?? ordered.first
            let parts = calendar.dateComponents([.hour,.minute], from: usage.timestamp)
            let legacy = usage.legacyCumulative
            let id: Int64
            if let existing {
                id = existing["id"]
                for row in ordered where row["id"] as Int64 != id {
                    try db.execute(sql: "DELETE FROM usage WHERE id=?", arguments: [row["id"] as Int64])
                }
                let preferIncoming = usage.evidence.record != nil && (existing["response_id"] as String?) == nil
                let columns = ["response_id","model","tier","reasoning_effort","legacy_total","legacy_input","legacy_output",
                    "legacy_cache_read","legacy_cache_write","legacy_reasoning","turn_started_at"]
                let values: [(any DatabaseValueConvertible)?] = [
                    usage.responseID ?? existing["response_id"], usage.model ?? existing["model"], tier ?? existing["tier"],
                    usage.evidence.reasoningEffort ?? existing["reasoning_effort"],
                    legacy?.totalTokens ?? existing["legacy_total"], legacy == nil ? (existing["legacy_input"] as Int64?) : legacy?.inputTokens,
                    legacy == nil ? (existing["legacy_output"] as Int64?) : legacy?.outputTokens, legacy == nil ? (existing["legacy_cache_read"] as Int64?) : legacy?.cachedInputTokens,
                    legacy == nil ? (existing["legacy_cache_write"] as Int64?) : legacy?.cacheWriteInputTokens, legacy == nil ? (existing["legacy_reasoning"] as Int64?) : legacy?.reasoningOutputTokens,
                    min(start, (existing["turn_started_at"] as Double?) ?? start)]
                let assignments = columns.map { "\($0)=?" }.joined(separator: ",")
                let unchanged = columns.map { "\($0) IS ?" }.joined(separator: " AND ")
                try db.execute(sql: "UPDATE usage SET \(assignments) WHERE id=? AND NOT (\(unchanged))",
                    arguments: StatementArguments(values + [id] + values))
                let changed = db.changesCount > 0 || ordered.count > 1 || preferIncoming
                if preferIncoming {
                    try db.execute(sql: "UPDATE usage SET occurred_at=?,usage_date=?,hour=?,minute=?,rollout_id=?,source_line=?,source_ordinal=? WHERE id=?",
                        arguments: [time,usage.timestamp.formatted(.iso8601.year().month().day().dateSeparator(.dash)),
                            parts.hour,parts.minute,usage.rolloutID,usage.line,usage.evidence.ordinal.flatMap(Int64.init(exactly:)),id])
                }
                if changed { upgraded += 1 } else { duplicates += 1; continue }
            } else {
                try db.execute(sql: """
                    INSERT INTO usage(turn_key,thread_id,turn_id,response_id,occurred_at,usage_date,hour,minute,model,tier,reasoning_effort,
                        input_tokens,output_tokens,cache_read_tokens,cache_write_tokens,reasoning_tokens,total_tokens,
                        source,rollout_id,source_line,source_ordinal,turn_started_at,source_created_at,
                        legacy_total,legacy_input,legacy_output,legacy_cache_read,legacy_cache_write,legacy_reasoning)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,'local',?,?,?,?,?,?,?,?,?,?,?)
                    """, arguments: [key,usage.threadID,usage.turnID,usage.responseID,time,
                        usage.timestamp.formatted(.iso8601.year().month().day().dateSeparator(.dash)),parts.hour,parts.minute,
                        usage.model,tier,usage.evidence.reasoningEffort,usage.tokens.inputTokens,usage.tokens.outputTokens,
                        usage.tokens.cachedInputTokens,usage.tokens.cacheWriteInputTokens,usage.tokens.reasoningOutputTokens,usage.tokens.totalTokens,
                        usage.rolloutID,usage.line,usage.evidence.ordinal.flatMap(Int64.init(exactly:)),start,created,
                        legacy?.totalTokens,legacy?.inputTokens,legacy?.outputTokens,legacy?.cachedInputTokens,
                        legacy?.cacheWriteInputTokens,legacy?.reasoningOutputTokens])
                id = db.lastInsertedRowID; inserted += 1
            }
            if let row = try Row.fetchOne(db, sql: "SELECT * FROM usage WHERE id=?", arguments: [id]) { _ = try priceUsage(row, db: db) }
        }
        return (inserted, upgraded, duplicates)
    }
}
