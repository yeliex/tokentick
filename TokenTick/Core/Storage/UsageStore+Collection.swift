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
            let result = try Self.collectTurns(usages, session: state.session, db: db)
            inserted = result.inserted
            upgraded = result.upgraded
            duplicates = result.duplicates
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

}
