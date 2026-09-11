import Foundation
import GRDB

extension UsageStore {
    private struct ConflictingEvent: Error, LocalizedError {
        var errorDescription: String? { "同一用量事件的身份或分项冲突，未推进明细和扫描游标。" }
    }

    /// turn 只确定所有权；每条有效消耗单独保存，不在采集时归并模型或日期。
    static func collectTurns(_ usages: [CollectedUsage], session: RolloutEvent.Session?, db: Database) throws
        -> (inserted: Int, upgraded: Int, duplicates: Int) {
        var inserted = 0, upgraded = 0, duplicates = 0
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .gmt
        for usage in usages {
            let key = usage.turnID.map { "turn:" + $0 } ?? "unattributed:" + usage.threadID
            let time = usage.timestamp.timeIntervalSince1970
            guard try claimTurn(usage, session: session, key: key, db: db) else {
                duplicates += 1
                continue
            }
            let tier = CodexServiceTier.normalized(usage.evidence.serviceTier)
            let matches = try matchingUsage(usage, key: key, tier: tier, encoder: encoder, db: db)
            let (existing, preferIncoming, json) = try mergeUsageReports(usage, matches: matches, encoder: encoder, db: db)
            let id: Int64
            if let existing {
                id = existing["id"]
                let oldProof: String = existing["evidence_json"]
                let oldResponse: String? = existing["response_id"], oldModel: String? = existing["model"], oldTier: String? = existing["tier"]
                if oldProof == json && (usage.responseID == nil || oldResponse == usage.responseID)
                    && (usage.model == nil || oldModel == usage.model) && (tier == nil || oldTier == tier) {
                    duplicates += 1; continue
                }
                try db.execute(sql: "UPDATE usage SET response_id=COALESCE(response_id,?),model=COALESCE(model,?),tier=COALESCE(tier,?),evidence_json=? WHERE id=?",
                    arguments: [usage.responseID,usage.model,tier,json,id])
                if preferIncoming {
                    let parts = calendar.dateComponents([.hour,.minute], from: usage.timestamp)
                    try db.execute(sql: "UPDATE usage SET occurred_at=?,usage_date=?,hour=?,minute=?,rollout_id=?,source_line=?,source_ordinal=? WHERE id=?",
                        arguments: [time,usage.timestamp.formatted(.iso8601.year().month().day().dateSeparator(.dash)),
                            parts.hour,parts.minute,usage.rolloutID,usage.line,usage.evidence.ordinal.flatMap(Int64.init(exactly:)),id])
                }
                upgraded += 1
            } else {
                let parts = calendar.dateComponents([.hour,.minute], from: usage.timestamp)
                try db.execute(sql: """
                    INSERT INTO usage(turn_key,thread_id,turn_id,response_id,occurred_at,usage_date,hour,minute,model,tier,
                        input_tokens,output_tokens,cache_read_tokens,cache_write_tokens,reasoning_tokens,total_tokens,
                        source,rollout_id,source_line,source_ordinal,evidence_json)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,'local',?,?,?,?)
                    """, arguments: [key,usage.threadID,usage.turnID,usage.responseID,time,
                        usage.timestamp.formatted(.iso8601.year().month().day().dateSeparator(.dash)),parts.hour,parts.minute,usage.model,tier,
                        usage.tokens.inputTokens,usage.tokens.outputTokens,usage.tokens.cachedInputTokens,
                        usage.tokens.cacheWriteInputTokens,usage.tokens.reasoningOutputTokens,usage.tokens.totalTokens,
                        usage.rolloutID,usage.line,usage.evidence.ordinal.flatMap(Int64.init(exactly:)),json])
                id = db.lastInsertedRowID; inserted += 1
            }
            if let row = try Row.fetchOne(db, sql: "SELECT * FROM usage WHERE id=?", arguments: [id]) { _ = try priceUsage(row, db: db) }
        }
        return (inserted, upgraded, duplicates)
    }

    // 所有权变更和后续明细写入共用调用方事务，后续冲突会一并回滚。
    private static func claimTurn(_ usage: CollectedUsage, session: RolloutEvent.Session?, key: String, db: Database) throws -> Bool {
        let time = usage.timestamp.timeIntervalSince1970
        let start = usage.evidence.turnStartedAt.flatMap(DateParsing.parseTimestamp)?.timeIntervalSince1970 ?? time
        let created = session?.timestamp.flatMap(DateParsing.parseTimestamp)?.timeIntervalSince1970
        if let owner = try Row.fetchOne(db, sql: "SELECT * FROM turn_usage WHERE id=?", arguments: [key]) {
            let thread: String = owner["thread_id"]
            if thread != usage.threadID {
                guard let created, let old: Double = owner["source_created_at"], created < old else {
                    return false
                }
                // 最早来源晚到时只留该来源，不为 fork 副本保存用量事实。
                try db.execute(sql: "DELETE FROM usage WHERE turn_key=?", arguments: [key])
                try db.execute(sql: "UPDATE turn_usage SET thread_id=?,source_created_at=?,started_at=?,last_event_at=? WHERE id=?",
                    arguments: [usage.threadID,created,start,time,key])
            } else {
                try db.execute(sql: "UPDATE turn_usage SET started_at=MIN(started_at,?),last_event_at=MAX(last_event_at,?) WHERE id=?",
                    arguments: [start,time,key])
            }
        } else {
            try db.execute(sql: "INSERT INTO turn_usage(id,turn_id,thread_id,source_created_at,started_at,last_event_at) VALUES (?,?,?,?,?,?)",
                arguments: [key,usage.turnID,usage.threadID,created,start,time])
        }
        return true
    }

    private static func matchingUsage(_ usage: CollectedUsage, key: String, tier: String?, encoder: JSONEncoder, db: Database) throws -> [Row] {
        var matches: [Int64: Row] = [:]
        if let response = usage.responseID,
           let row = try Row.fetchOne(db, sql: "SELECT * FROM usage WHERE turn_key=? AND response_id=?", arguments: [key,response]) {
            matches[row["id"]] = row
        }
        if let cumulative = usage.legacyCumulative {
            let candidates = try Row.fetchAll(db, sql: """
                SELECT * FROM usage WHERE turn_key=? AND json_extract(evidence_json,'$.legacyCumulative.total_tokens')=?
                    AND (? IS NULL OR response_id IS NULL OR response_id=?)
                """, arguments: [key,cumulative.totalTokens,usage.responseID,usage.responseID])
            for row in candidates {
                let raw: String = row["evidence_json"]
                let proof = try JSONDecoder().decode(SourceJSON.self, from: Data(raw.utf8))
                if let value = proof["legacyCumulative"],
                   try JSONDecoder().decode(TokenUsage.self, from: encoder.encode(value)) == cumulative {
                    matches[row["id"]] = row
                }
            }
        }
        for row in matches.values {
            let tokens = TokenUsage(inputTokens: row["input_tokens"], outputTokens: row["output_tokens"],
                cachedInputTokens: row["cache_read_tokens"], cacheWriteInputTokens: row["cache_write_tokens"],
                reasoningOutputTokens: row["reasoning_tokens"], totalTokens: row["total_tokens"])
            guard tokens == usage.tokens, row["turn_key"] as String? == key else { throw ConflictingEvent() }
            if let response: String = row["response_id"], let incoming = usage.responseID, response != incoming { throw ConflictingEvent() }
            if let model: String = row["model"], let incoming = usage.model, model != incoming { throw ConflictingEvent() }
            if let mode: String = row["tier"], let tier, mode != tier { throw ConflictingEvent() }
        }
        return matches.values.sorted { ($0["id"] as Int64) < ($1["id"] as Int64) }
    }

    /// 合并报告证据时删除已确认的重复行，返回保留行和本次采用的主报告。
    private static func mergeUsageReports(_ usage: CollectedUsage, matches ordered: [Row], encoder: JSONEncoder, db: Database) throws
        -> (existing: Row?, preferIncoming: Bool, json: String) {
        // 明确响应优先作为主报告；旧报告保留在同一行的证据中。
        let existing = ordered.first { ($0["response_id"] as String?) != nil } ?? ordered.first
        var proof: [String: SourceJSON] = [:]
        var alternatives: [SourceJSON] = []
        let incoming = try JSONDecoder().decode(SourceJSON.self, from: encoder.encode(usage.evidence))
        let preferIncoming = existing == nil || (usage.evidence.record != nil && (existing?["response_id"] as String?) == nil)
        if let existing {
            let raw: String = existing["evidence_json"]
            if case .object(let value) = try JSONDecoder().decode(SourceJSON.self, from: Data(raw.utf8)) { proof = value }
            if case .array(let values) = proof["alternateReports"] { alternatives = values }
        }
        let previousReport = proof["report"]
        if preferIncoming || previousReport == nil { proof["report"] = incoming }
        func appendReport(_ report: SourceJSON?) {
            guard let report, report != proof["report"], !alternatives.contains(report) else { return }
            alternatives.append(report)
        }
        appendReport(previousReport); appendReport(incoming)
        for row in ordered where row["id"] as Int64? != existing?["id"] as Int64? {
            let raw: String = row["evidence_json"]
            let other = try JSONDecoder().decode(SourceJSON.self, from: Data(raw.utf8))
            appendReport(other["report"])
            if case .array(let values) = other["alternateReports"] { for value in values { appendReport(value) } }
            try db.execute(sql: "DELETE FROM usage WHERE id=?", arguments: [row["id"] as Int64])
        }
        if !alternatives.isEmpty { proof["alternateReports"] = .array(alternatives) }
        if let cumulative = usage.legacyCumulative {
            proof["legacyCumulative"] = try JSONDecoder().decode(SourceJSON.self, from: encoder.encode(cumulative))
        }
        if case .object(let fields) = proof["report"] {
            for name in ["serviceTier", "modelSource", "serviceTierSource", "threadSettings", "turnStartedLine", "turnStartedAt", "modelCandidates"] {
                if let value = fields[name] { proof[name] = value }
            }
        }
        let json = String(decoding: try encoder.encode(proof), as: UTF8.self)
        return (existing, preferIncoming, json)
    }
}
