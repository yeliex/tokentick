import Foundation
import GRDB

extension UsageStore {
    func fastEvidenceCursor(key: String) throws -> CodexFastEvidence.Cursor? {
        try pool.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM app_metadata WHERE key = ?", arguments: [key])
                .flatMap { try? JSONDecoder().decode(CodexFastEvidence.Cursor.self, from: Data($0.utf8)) }
        }
    }

    /// 调用者持有扫描写锁；补证、对应金额和来源游标必须同一事务提交。
    func commitFastEvidence(_ batch: [CodexFastEvidence], cursor: CodexFastEvidence.Cursor, key: String) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try pool.write { target in
            for evidence in batch {
                let json = String(decoding: try encoder.encode(evidence), as: UTF8.self)
                try target.execute(sql: "INSERT INTO app_metadata(key,value) VALUES (?,?) ON CONFLICT DO NOTHING", arguments: [evidence.key, json])
                if target.changesCount > 0 {
                    let usage = try Row.fetchCursor(target, sql: "SELECT * FROM usage WHERE thread_id=? AND turn_id=? AND tier IS NULL", arguments: [evidence.threadID, evidence.turnID])
                    while let row = try usage.next() { _ = try Self.priceUsage(row, db: target) }
                }
            }
            try target.execute(sql: "INSERT INTO app_metadata(key,value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                               arguments: [key, String(decoding: try encoder.encode(cursor), as: UTF8.self)])
        }
    }
}
