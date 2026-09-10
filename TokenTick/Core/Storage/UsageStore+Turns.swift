import CryptoKit
import Foundation
import GRDB

extension UsageStore {
    private struct SeenEvent: Codable {
        let digest: String
        let canonicalKey: String
        let partKey: String
    }
    private struct ConflictingEvent: Error, LocalizedError {
        var errorDescription: String? { "同一用量事件的 token 分项冲突，未推进轮次和扫描游标。" }
    }
    private struct TokenOverflow: Error, LocalizedError {
        var errorDescription: String? { "轮次累计 token 超过 Int64 上限，未推进轮次和扫描游标。" }
    }
    private struct TurnState {
        var thread: String
        var created: Double
        var started: Double
        var last: Double
        var seen: [String: SeenEvent]
    }

    /// 只在一个采集批次内缓存触及的轮次；持久化的是轮次及其汇总分项，不是请求行。
    static func collectTurns(_ usages: [CollectedUsage], session: RolloutEvent.Session?, db: Database) throws
        -> (inserted: Int, upgraded: Int, duplicates: Int) {
        var turns: [String: TurnState] = [:]
        var pricedParts: Set<Int64> = []
        var inserted = 0, upgraded = 0, duplicates = 0
        let zoneName = try String.fetchOne(db, sql: "SELECT value FROM app_metadata WHERE key='statistics_timezone'") ?? TimeZone.current.identifier
        let zone = TimeZone(identifier: zoneName) ?? .gmt
        let dayFormat = Date.ISO8601FormatStyle(timeZone: zone).year().month().day().dateSeparator(.dash)
        for usage in usages {
            // 无轮次 ID 的旧来源单独保留未知归属，不伪造一个 turnId。
            let key = usage.turnID.map { "turn:" + $0 } ?? "unattributed:" + usage.threadID
            let time = usage.timestamp.timeIntervalSince1970
            let created = session?.timestamp.flatMap(RolloutParser.parseDate)?.timeIntervalSince1970 ?? time
            if turns[key] == nil {
                if let row = try Row.fetchOne(db, sql: "SELECT * FROM turn_usage WHERE id=?", arguments: [key]) {
                    let json: String = row["seen_json"]
                    turns[key] = TurnState(thread: row["thread_id"], created: row["source_created_at"],
                        started: row["started_at"], last: row["last_event_at"],
                        seen: try JSONDecoder().decode([String: SeenEvent].self, from: Data(json.utf8)))
                } else {
                    turns[key] = TurnState(thread: usage.threadID, created: created, started: time, last: time, seen: [:])
                    try db.execute(sql: """
                        INSERT INTO turn_usage(id,turn_id,thread_id,source_created_at,started_at,last_event_at,seen_json)
                        VALUES (?,?,?,?,?,?, '{}')
                        """, arguments: [key, usage.turnID, usage.threadID, created, time, time])
                }
            }
            var turn = turns[key]!
            if turn.thread != usage.threadID {
                guard created < turn.created else { duplicates += 1; continue }
                // 更早的原始任务晚到时整体替换归属；不能将其完整轮次叠加到 fork 副本上。
                try db.execute(sql: "DELETE FROM usage WHERE turn_key=?", arguments: [key])
                turn = TurnState(thread: usage.threadID, created: created, started: time, last: time, seen: [:])
            }
            turn.started = min(turn.started, time); turn.last = max(turn.last, time)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let digest = SHA256.hash(data: try encoder.encode(usage.tokens)).map { String(format: "%02x", $0) }.joined()
            let known = turn.seen[usage.dedupKey]
            let replaced = usage.replacesKey.flatMap { turn.seen[$0] }
            if let known, known.digest != digest { throw ConflictingEvent() }
            if let replaced, replaced.digest != digest { throw ConflictingEvent() }
            if let known {
                if let part = try Row.fetchOne(db, sql: "SELECT model,is_fast FROM usage WHERE dedup_key=?", arguments: [known.partKey]) {
                    if let model: String = part["model"], let current = usage.model, model != current { throw ConflictingEvent() }
                    if let fast: Bool = part["is_fast"], let current = usage.isFast, fast != current { throw ConflictingEvent() }
                }
                if let replaced, replaced.canonicalKey != known.canonicalKey {
                    let names = ["input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens", "reasoning_tokens", "total_tokens"]
                    let values: [Int64?] = [usage.tokens.inputTokens,usage.tokens.outputTokens,usage.tokens.cachedInputTokens,
                        usage.tokens.cacheWriteInputTokens,usage.tokens.reasoningOutputTokens,usage.tokens.totalTokens]
                    try db.execute(sql: "UPDATE usage SET \(names.map { "\($0)=\($0)-?" }.joined(separator: ",")) WHERE dedup_key=?",
                        arguments: StatementArguments(values) + [replaced.partKey])
                    if let id = try Int64.fetchOne(db, sql: "SELECT id FROM usage WHERE dedup_key=?", arguments: [replaced.partKey]) { pricedParts.insert(id) }
                    try db.execute(sql: "DELETE FROM usage WHERE dedup_key=? AND total_tokens=0", arguments: [replaced.partKey])
                    upgraded += 1
                }
                if let alias = usage.replacesKey { turn.seen[alias] = known }
                turns[key] = turn; duplicates += 1; continue
            }
            if let replaced {
                turn.seen[usage.dedupKey] = replaced
                turns[key] = turn; upgraded += 1; continue
            }

            let date = usage.timestamp.formatted(.iso8601.year().month().day().dateSeparator(.dash))
            let price = try usage.model.flatMap { try modelPrice(db: db, model: $0, date: date) }
            let isLong: Bool? = price.flatMap {
                switch $0.contextRule {
                case .uniform: false
                case .requestInputGreaterThan: $0.longContextThreshold.map { usage.tokens.inputTokens > $0 }
                case .unsupported: nil
                }
            }
            let components: [Any] = [key, usage.model as Any? ?? NSNull(), date, usage.timestamp.formatted(dayFormat),
                                     usage.isFast as Any? ?? NSNull(), isLong as Any? ?? NSNull()]
            let partKey = "turn-part:" + SHA256.hash(data: try JSONSerialization.data(withJSONObject: components))
                .map { String(format: "%02x", $0) }.joined()
            let seen = SeenEvent(digest: digest, canonicalKey: usage.dedupKey, partKey: partKey)
            turn.seen[usage.dedupKey] = seen
            if let alias = usage.replacesKey { turn.seen[alias] = seen }
            turns[key] = turn
            var evidence: [String: Any] = ["aggregation": "turn", "firstFileName": usage.evidence.fileName,
                "firstLine": usage.line, "firstTimestamp": usage.evidence.timestamp,
                "lastFileName": usage.evidence.fileName, "lastLine": usage.line, "lastTimestamp": usage.evidence.timestamp]
            if let tier = usage.evidence.serviceTier { evidence["serviceTier"] = tier }
            let source = try JSONSerialization.jsonObject(with: encoder.encode(usage.evidence)) as? [String: Any] ?? [:]
            for name in ["modelSource", "serviceTierSource", "threadSettings", "turnStartedLine", "modelCandidates"] {
                evidence[name] = source[name]
            }
            let json = String(decoding: try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys]), as: UTF8.self)
            let columns = ["input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens", "reasoning_tokens"]
            let add = columns.map { "\($0) = CASE WHEN usage.\($0) IS NULL OR excluded.\($0) IS NULL THEN NULL ELSE usage.\($0)+excluded.\($0) END" }.joined(separator: ",")
            try db.execute(sql: """
                INSERT INTO usage(dedup_key,turn_key,thread_id,turn_id,occurred_at,usage_date,model,is_fast,is_long_context,
                    input_tokens,output_tokens,cache_read_tokens,cache_write_tokens,reasoning_tokens,total_tokens,
                    source,rollout_id,source_line,evidence_json,pricing_input_min,pricing_input_max)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,'local',?,?,?,?,?)
                ON CONFLICT(dedup_key) DO UPDATE SET \(add), total_tokens=usage.total_tokens+excluded.total_tokens,
                    occurred_at=MIN(usage.occurred_at,excluded.occurred_at),
                    occurred_through=MAX(COALESCE(usage.occurred_through,usage.occurred_at),excluded.occurred_at),
                    pricing_input_min=MIN(usage.pricing_input_min,excluded.pricing_input_min),
                    pricing_input_max=MAX(usage.pricing_input_max,excluded.pricing_input_max),
                    evidence_json=json_set(usage.evidence_json,'$.lastFileName',json_extract(excluded.evidence_json,'$.lastFileName'),
                        '$.lastLine',excluded.source_line,'$.lastTimestamp',json_extract(excluded.evidence_json,'$.lastTimestamp'))
                """, arguments: [partKey,key,usage.threadID,usage.turnID,time,date,usage.model,usage.isFast,isLong,
                    usage.tokens.inputTokens,usage.tokens.outputTokens,usage.tokens.cachedInputTokens,
                    usage.tokens.cacheWriteInputTokens,usage.tokens.reasoningOutputTokens,usage.tokens.totalTokens,
                    usage.rolloutID,usage.line,json,usage.tokens.inputTokens,usage.tokens.inputTokens])
            // SQLite 的逐项加法溢出会转成 REAL；不能让精确 token 悄悄变成浮点数。
            let integers = (columns + ["total_tokens"]).map { "typeof(\($0)) IN ('integer','null')" }.joined(separator: " AND ")
            if let row = try Row.fetchOne(db, sql: "SELECT id, (\(integers)) AS valid FROM usage WHERE dedup_key=?", arguments: [partKey]) {
                guard row["valid"] as Bool else { throw TokenOverflow() }
                pricedParts.insert(row["id"])
            }
            inserted += 1
        }
        for (key, turn) in turns {
            let json = String(decoding: try JSONEncoder().encode(turn.seen), as: UTF8.self)
            try db.execute(sql: """
                UPDATE turn_usage SET thread_id=?,source_created_at=?,started_at=?,last_event_at=?,seen_json=? WHERE id=?
                """, arguments: [turn.thread,turn.created,turn.started,turn.last,json,key])
        }
        for id in pricedParts {
            if let row = try Row.fetchOne(db, sql: "SELECT * FROM usage WHERE id=?", arguments: [id]) { _ = try priceUsage(row, db: db) }
        }
        return (inserted, upgraded, duplicates)
    }
}
