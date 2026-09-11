import Foundation
import GRDB

extension UsageStore {
    func saveSynchronizationReport(_ report: SynchronizationReport) throws {
        let json = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        try FileWriteLock(url: databaseURL.appendingPathExtension("write.lock")).withLock {
            try pool.write { db in
                try db.execute(sql: "INSERT INTO app_metadata(key, value) VALUES ('last_sync_report', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", arguments: [json])
            }
        }
    }

    public func lastSynchronizationReport() throws -> SynchronizationReport? {
        try pool.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM app_metadata WHERE key = 'last_sync_report'")
                .map { try JSONDecoder().decode(SynchronizationReport.self, from: Data($0.utf8)) }
        }
    }
}
