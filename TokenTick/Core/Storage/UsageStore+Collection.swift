import Foundation
import GRDB

extension UsageStore {
    func restoreWeeklyWindows() throws {
        // Restore all cursors first so a new window in another file can close a previous cycle.
        let windows = try pool.read { db in
            let completed = try Row.fetchAll(db, sql: "SELECT account_id,scheduled_reset_at FROM weekly_limit_cycles")
            let states = try String.fetchAll(db, sql: "SELECT parser_state_json FROM scan_files WHERE parser_state_json IS NOT NULL")
            return states.flatMap { json -> [WeeklyCycleCalculator.Window] in
                guard let state = try? JSONDecoder().decode(RolloutParserState.self, from: Data(json.utf8)),
                      state.version == RolloutParserState.currentVersion else { return [] }
                return (state.weeklyWindows ?? []).filter { window in
                    !completed.contains { row in
                        let account: String? = row["account_id"]
                        let reset: Int64 = row["scheduled_reset_at"]
                        return account == window.account && abs(reset-window.reset) <= 60
                    }
                }
            }
        }
        weeklyMemory.withLock { memory in
            for window in windows { memory.merge(window) }
        }
    }

    func scanCursor(rolloutID: String) throws -> ScanCursor? {
        try pool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM scan_files WHERE rollout_id = ?", arguments: [rolloutID]),
                  let fileJSON: String = row["file_state_json"], let stateJSON: String = row["parser_state_json"],
                  let file = try? JSONDecoder().decode(FileSnapshot.self, from: Data(fileJSON.utf8)),
                  let state = try? JSONDecoder().decode(RolloutParserState.self, from: Data(stateJSON.utf8)) else { return nil }
            return ScanCursor(path: row["current_path"], line: row["scanned_line"], offset: row["scanned_offset"], file: file, state: state)
        }
    }

    func updateScanPath(rolloutID: String, url: URL) throws {
        try pool.write { db in
            try db.execute(sql: "UPDATE scan_files SET current_path = ?, last_scanned_at = ? WHERE rollout_id = ?",
                           arguments: [url.path, Date().timeIntervalSince1970, rolloutID])
        }
    }

    func commitScan(_ usages: [CollectedUsage], limits: [CurrentLimitSnapshot] = [], identity: RolloutIdentity, url: URL, line: Int, offset: UInt64,
                    file: FileSnapshot, state: inout RolloutParserState, completed: Bool, report: inout ScanReport) throws {
        var file = file
        file.completed = completed
        if !file.compressed {
            file.prefixHash = try FileSnapshot.hash(url: url, offset: 0, count: Int(min(offset, 4_096)))
            file.tailHash = try FileSnapshot.hash(url: url, offset: offset - min(offset, 4_096), count: Int(min(offset, 4_096)))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let fileJSON = String(decoding: try encoder.encode(file), as: UTF8.self)
        var savedState = state
        let counts = try weeklyMemory.withLock { memory in
            var updated = memory
            var checkpoint = WeeklyCycleCalculator()
            for window in state.weeklyWindows ?? [] { checkpoint.merge(window) }
            let counts = try pool.write { db in
                let counts = try Self.collectTurns(usages, session: state.session, db: db)
                for snapshot in try Self.acceptedWeeklyLimits(limits, db: db) {
                    updated.consume(snapshot)
                    checkpoint.consume(snapshot)
                }
                // Retain this file's last window per account; commit ended cycles and the cursor together.
                savedState.weeklyWindows = checkpoint.windows.filter { window in
                    !checkpoint.windows.contains { $0.account == window.account && $0.last > window.last }
                }
                let stateJSON = String(decoding: try encoder.encode(savedState), as: UTF8.self)
                let changed = try updated.saveCompleted(db: db, now: Date().timeIntervalSince1970)
                if changed > 0 {
                    try db.execute(sql: "DELETE FROM app_metadata WHERE key='weekly_cycles_revision'")
                }
                let threadID = identity.threadID.uuidString.lowercased()
                // Resolve names from current Codex task metadata rather than guessing projects from paths.
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
                return counts
            }
            memory = updated
            return counts
        }
        state = savedState
        report.insertedRequests += counts.inserted
        report.upgradedRequests += counts.upgraded
        report.duplicateRequests += counts.duplicates
    }

}
