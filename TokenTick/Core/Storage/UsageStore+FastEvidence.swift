import Foundation
import GRDB

extension UsageStore {
    static func applyBillingMode(_ mode: String, device: String, thread: String, turn: String, db: Database) throws {
        let rows = try Row.fetchAll(db, sql: """
            UPDATE usage SET billing_mode=? WHERE turn_key=? AND thread_id=? AND device=? AND billing_mode<>? RETURNING *
            """, arguments: [mode, "turn:" + turn, thread, device, mode])
        for row in rows { _ = try priceUsage(row, db: db) }
    }

    func fastEvidenceCursor(key: String) throws -> CodexFastEvidence.Cursor? {
        try pool.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM app_metadata WHERE key = ?", arguments: [key])
                .flatMap { try? JSONDecoder().decode(CodexFastEvidence.Cursor.self, from: Data($0.utf8)) }
        }
    }

    /// The caller holds the scan write lock; commit evidence, prices, and source cursors in one transaction.
    func commitTraceEvidence(_ batch: [CodexFastEvidence], page: DeviceTracePage, device: String, key: String) throws -> Bool {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try pool.write { target in
            var authenticationChanged = false
            for entry in page.entries {
                guard let mode = entry.authMode, let thread = entry.threadID.flatMap(UUID.init(uuidString:)),
                      let turn = entry.authTurn.flatMap(UUID.init(uuidString:)) else { continue }
                let authKey = "turn_auth:\(device):\(thread.uuidString.lowercased()):\(turn.uuidString.lowercased())"
                try target.execute(sql: """
                    INSERT INTO app_metadata(key,value) VALUES (?, CASE WHEN EXISTS(
                        SELECT 1 FROM usage WHERE turn_key=? AND thread_id=? AND device=? AND billing_mode='plan'
                    ) THEN 'plan' ELSE ? END)
                    ON CONFLICT(key) DO UPDATE SET value='mixed' WHERE value<>? AND value NOT IN ('mixed','plan')
                    """, arguments: [authKey, "turn:" + turn.uuidString.lowercased(), thread.uuidString.lowercased(), device, mode, mode])
                if target.changesCount > 0 {
                    authenticationChanged = true
                    let stored = try String.fetchOne(target, sql: "SELECT value FROM app_metadata WHERE key=?", arguments: [authKey])
                    try Self.applyBillingMode(stored == "chatgpt" || stored == "plan" ? "plan" : "api",
                        device: device, thread: thread.uuidString.lowercased(), turn: turn.uuidString.lowercased(), db: target)
                }
            }
            for evidence in batch {
                let json = String(decoding: try encoder.encode(evidence), as: UTF8.self)
                try target.execute(sql: "INSERT INTO app_metadata(key,value) VALUES (?,?) ON CONFLICT DO NOTHING", arguments: [evidence.key, json])
                if target.changesCount > 0 {
                    let usage = try Row.fetchCursor(target, sql: "SELECT * FROM usage WHERE thread_id=? AND turn_id=? AND tier IS NULL", arguments: [evidence.threadID, evidence.turnID])
                    while let row = try usage.next() { _ = try Self.priceUsage(row, db: target) }
                }
            }
            try target.execute(sql: "INSERT INTO app_metadata(key,value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                               arguments: [key, String(decoding: try encoder.encode(page.cursor), as: UTF8.self)])
            return authenticationChanged
        }
    }
}
