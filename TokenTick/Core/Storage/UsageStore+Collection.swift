import Foundation
import GRDB

extension UsageStore {
    func scanCursor(rolloutID: String) throws -> ScanCursor? {
        try pool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM scan_files WHERE rollout_id = ?", arguments: [rolloutID]),
                  let fileJSON: String = row["file_state_json"], let stateJSON: String = row["parser_state_json"],
                  let file = try? JSONDecoder().decode(FileSnapshot.self, from: Data(fileJSON.utf8)),
                  let state = try? JSONDecoder().decode(RolloutParserState.self, from: Data(stateJSON.utf8)) else { return nil }
            return ScanCursor(line: row["scanned_line"], offset: row["scanned_offset"], file: file, state: state)
        }
    }

    func updateScanPath(rolloutID: String, url: URL) throws {
        try pool.write { db in
            try db.execute(sql: "UPDATE scan_files SET current_path = ?, last_scanned_at = ? WHERE rollout_id = ?",
                           arguments: [url.path, Date().timeIntervalSince1970, rolloutID])
        }
    }

    func commitScan(_ usages: [CollectedUsage], limits: [CurrentLimitSnapshot] = [], identity: RolloutIdentity, url: URL, line: Int, offset: UInt64,
                    file: FileSnapshot, state: RolloutParserState, completed: Bool, report: inout ScanReport) throws {
        var file = file
        file.completed = completed
        if !file.compressed {
            file.prefixCount = Int(min(offset, 4_096))
            file.prefixHash = try FileSnapshot.hash(url: url, offset: 0, count: file.prefixCount)
            file.tailHash = try FileSnapshot.hash(url: url, offset: offset - min(offset, 4_096), count: Int(min(offset, 4_096)))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let fileJSON = String(decoding: try encoder.encode(file), as: UTF8.self)
        let stateJSON = String(decoding: try encoder.encode(state), as: UTF8.self)
        let counts = try pool.write { db -> (Int, Int, Int) in
            var inserted = 0
            var upgraded = 0
            var duplicates = 0
            for usage in usages {
                let outcome = try Self.insertUsage(usage, into: db, encoder: encoder)
                switch outcome {
                case .inserted: inserted += 1
                case .upgraded: upgraded += 1
                case .duplicate: duplicates += 1
                }
            }
            for snapshot in limits { _ = try Self.saveWeeklyObservations(snapshot, db: db) }
            let threadID = identity.threadID.uuidString.lowercased()
            // 名称由最新 Codex thread 缓存更新，不从路径猜出一个无法核验的项目名。
            try db.execute(sql: "INSERT INTO threads(thread_id) VALUES (?) ON CONFLICT DO NOTHING", arguments: [threadID])
            try db.execute(sql: """
                INSERT INTO scan_files(rollout_id, thread_id, file_name, current_path, scanned_line, scanned_offset,
                                       last_scanned_at, file_state_json, parser_state_json)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(rollout_id) DO UPDATE SET thread_id = excluded.thread_id, file_name = excluded.file_name,
                    current_path = excluded.current_path, scanned_line = excluded.scanned_line,
                    scanned_offset = excluded.scanned_offset, last_scanned_at = excluded.last_scanned_at,
                    file_state_json = excluded.file_state_json, parser_state_json = excluded.parser_state_json
                """, arguments: [identity.rolloutID.uuidString.lowercased(), threadID, identity.fileName, url.path,
                                  line, offset, Date().timeIntervalSince1970, fileJSON, stateJSON])
            return (inserted, upgraded, duplicates)
        }
        report.insertedRequests += counts.0
        report.upgradedRequests += counts.1
        report.duplicateRequests += counts.2
    }

    private enum InsertOutcome { case inserted, upgraded, duplicate }
    private struct UsageConflict: LocalizedError {
        var errorDescription: String? { "相同请求标识出现不同的用量事实；事务已回滚，游标未推进。" }
    }
    private struct MetadataConflict: LocalizedError {
        var errorDescription: String? { "相同请求的模型、模式或轮次出现冲突；未覆盖已知归属，游标未推进。" }
    }

    private static func insertUsage(_ usage: CollectedUsage, into db: Database, encoder: JSONEncoder) throws -> InsertOutcome {
        let existing = try Row.fetchOne(db, sql: "SELECT * FROM usage WHERE dedup_key = ?", arguments: [usage.dedupKey])
        if let existing {
            guard matches(existing, usage: usage) else { throw UsageConflict() }
            let enriched = try enrichUsage(existing, usage: usage, db: db, encoder: encoder)
            if let replaced = usage.replacesKey, replaced != usage.dedupKey {
                if let legacy = try Row.fetchOne(db, sql: "SELECT * FROM usage WHERE dedup_key = ?", arguments: [replaced]) {
                    guard matches(legacy, usage: usage) else { throw UsageConflict() }
                    try db.execute(sql: "DELETE FROM usage WHERE dedup_key = ?", arguments: [replaced])
                    try db.execute(sql: "UPDATE usage SET evidence_json = json_set(evidence_json, '$.legacyKey', ?) WHERE dedup_key = ?",
                                   arguments: [replaced, usage.dedupKey])
                    return .upgraded
                }
            }
            return enriched ? .upgraded : .duplicate
        }
        if usage.responseID == nil,
           let modern = try Row.fetchOne(db, sql: "SELECT * FROM usage WHERE source = 'local' AND json_extract(evidence_json, '$.legacyKey') = ?",
                                         arguments: [usage.dedupKey]) {
            guard matches(modern, usage: usage) else { throw UsageConflict() }
            return .duplicate
        }
        var evidence = usage.evidence
        evidence.legacyKey = usage.replacesKey
        let json = String(decoding: try encoder.encode(evidence), as: UTF8.self)
        if let replaced = usage.replacesKey,
           let legacy = try Row.fetchOne(db, sql: "SELECT * FROM usage WHERE dedup_key = ?", arguments: [replaced]) {
            guard matches(legacy, usage: usage) else { throw UsageConflict() }
            _ = try enrichUsage(legacy, usage: usage, db: db, encoder: encoder)
            try db.execute(sql: """
                UPDATE usage SET dedup_key = ?, response_id = ?, evidence_json = ?, source_line = ?, rollout_id = ?
                WHERE dedup_key = ?
                """, arguments: [usage.dedupKey, usage.responseID, json, usage.line, usage.rolloutID, replaced])
            return .upgraded
        }
        // 热路径复用语句，避免每个请求都重新编译用量表的失效触发器。
        let insert = try db.cachedStatement(sql: """
            INSERT INTO usage(dedup_key, thread_id, turn_id, response_id, occurred_at, usage_date,
                              model, is_fast, input_tokens, output_tokens, cache_read_tokens,
                              cache_write_tokens, reasoning_tokens, total_tokens, source,
                              rollout_id, source_line, evidence_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'local', ?, ?, ?)
            """)
        try insert.execute(arguments: [usage.dedupKey, usage.threadID, usage.turnID, usage.responseID,
                              usage.timestamp.timeIntervalSince1970,
                              usage.timestamp.formatted(.iso8601.year().month().day().dateSeparator(.dash)),
                              usage.model, usage.isFast, usage.tokens.inputTokens, usage.tokens.outputTokens,
                              usage.tokens.cachedInputTokens, usage.tokens.cacheWriteInputTokens,
                              usage.tokens.reasoningOutputTokens, usage.tokens.totalTokens,
                              usage.rolloutID, usage.line, json])
        if let row = try Row.fetchOne(db, sql: "SELECT * FROM usage WHERE id = ?", arguments: [db.lastInsertedRowID]) {
            _ = try priceUsage(row, db: db)
        }
        return .inserted
    }

    private static func enrichUsage(_ row: Row, usage: CollectedUsage, db: Database, encoder: JSONEncoder) throws -> Bool {
        let oldModel: String? = row["model"]
        let oldFast: Bool? = row["is_fast"]
        let oldTurn: String? = row["turn_id"]
        let oldJSON: String = row["evidence_json"]
        var evidence = try JSONSerialization.jsonObject(with: Data(oldJSON.utf8)) as? [String: Any] ?? [:]
        let newEvidence = try JSONSerialization.jsonObject(with: encoder.encode(usage.evidence)) as? [String: Any] ?? [:]
        // v1 的旧累计事件在前置压缩期间会沿用上一轮 ID。保持原去重键，修正已确认错位的归属并留痕。
        let legacyTurnRepair = oldTurn != nil && usage.turnID != nil && oldTurn != usage.turnID
            && (row["response_id"] as String?) == nil && evidence["record"] == nil
            && evidence["turnStartedLine"] == nil && usage.evidence.turnStartedLine != nil
        if !legacyTurnRepair {
            if let oldModel, let model = usage.model, oldModel != model { throw MetadataConflict() }
            if let oldFast, let fast = usage.isFast, oldFast != fast { throw MetadataConflict() }
            if let oldTurn, let turn = usage.turnID, oldTurn != turn { throw MetadataConflict() }
        } else {
            evidence["attributionRepair"] = ["previousModel": oldModel as Any? ?? NSNull(),
                "previousFast": oldFast as Any? ?? NSNull(), "previousTurn": oldTurn as Any? ?? NSNull(),
                "reason": "task_started_before_turn_context", "rolloutID": usage.rolloutID,
                "fileName": usage.evidence.fileName]
        }
        // 保留原请求事件与定位，只增补带独立 rollout／行号的上下文证据。
        for key in ["modelSource", "serviceTierSource", "threadSettings", "turnStartedLine", "modelCandidates"] {
            if let value = newEvidence[key] { evidence[key] = value }
        }
        if usage.evidence.serviceTierSource != nil {
            evidence["serviceTier"] = newEvidence["serviceTier"]
        }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys]), as: UTF8.self)
        let model = legacyTurnRepair ? usage.model : oldModel ?? usage.model
        let fast = legacyTurnRepair ? usage.isFast : oldFast ?? usage.isFast
        let turn = legacyTurnRepair ? usage.turnID : oldTurn ?? usage.turnID
        guard model != oldModel || fast != oldFast || turn != oldTurn || json != oldJSON else { return false }
        let update = try db.cachedStatement(sql: "UPDATE usage SET model = ?, is_fast = ?, turn_id = ?, evidence_json = ? WHERE id = ?")
        let id: Int64 = row["id"]
        try update.execute(arguments: [model, fast, turn, json, id])
        if model != oldModel || fast != oldFast,
           let enriched = try Row.fetchOne(db, sql: "SELECT * FROM usage WHERE id = ?", arguments: [id]) {
            _ = try priceUsage(enriched, db: db)
        }
        return true
    }

    private static func matches(_ row: Row, usage: CollectedUsage) -> Bool {
        let thread: String? = row["thread_id"]
        let input: Int64? = row["input_tokens"]
        let output: Int64? = row["output_tokens"]
        let cached: Int64? = row["cache_read_tokens"]
        let write: Int64? = row["cache_write_tokens"]
        let reasoning: Int64? = row["reasoning_tokens"]
        let total: Int64 = row["total_tokens"]
        return thread == usage.threadID && input == usage.tokens.inputTokens && output == usage.tokens.outputTokens
            && cached == usage.tokens.cachedInputTokens && write == usage.tokens.cacheWriteInputTokens
            && reasoning == usage.tokens.reasoningOutputTokens && total == usage.tokens.totalTokens
    }
}
