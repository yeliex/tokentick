import Foundation
import GRDB
import Testing
@testable import TokenTickCore

struct UsageStoreTests {
    @Test func newStoreCreatesExpectedTablesAndKeepsUnknownValues() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("usage.sqlite")
        let store = try UsageStore(databaseURL: url)
        #expect(try store.tableCounts().count == 7)
        try store.pool.write { db in
            try db.execute(sql: "INSERT INTO usage (dedup_key, total_tokens, usage_date, source, evidence_json) VALUES ('api-day', 100, '2026-09-09', 'api', '{}')")
        }
        let reopened = try UsageStore(databaseURL: url)
        #expect(try reopened.tableCounts()["usage"] == 1)
        let row = try reopened.pool.read { db in try Row.fetchOne(db, sql: "SELECT amount, model, is_fast FROM usage") }
        #expect(row?["amount"] as Int64? == nil)
        #expect(row?["model"] as String? == nil)
        #expect(row?["is_fast"] as Bool? == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("Backups").path))
    }

    @Test func unknownFutureMigrationRefusesToOpen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("usage.sqlite")
        let store = try UsageStore(databaseURL: url)
        try store.pool.write { db in
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v999.future')")
        }
        #expect(throws: UsageStore.StoreError.newerSchema) { try UsageStore(databaseURL: url) }
        #expect(try store.pool.read { db in try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations") }.contains("v999.future"))
    }

    @Test func migrationBacksUpExistingUnmigratedDatabase() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("usage.sqlite")
        let original = try DatabaseQueue(path: url.path)
        try original.write { db in
            try db.execute(sql: "CREATE TABLE existing_data (value TEXT); INSERT INTO existing_data VALUES ('keep')")
        }
        _ = try UsageStore(databaseURL: url)
        let backups = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("Backups"), includingPropertiesForKeys: nil)
        let backup = try #require(backups.first(where: { $0.pathExtension == "sqlite" }))
        var configuration = Configuration()
        configuration.readonly = true
        let restored = try DatabaseQueue(path: backup.path, configuration: configuration)
        #expect(try restored.read { db in try String.fetchOne(db, sql: "SELECT value FROM existing_data") } == "keep")
        #expect(try restored.read { db in try db.tableExists("usage") } == false)
    }
    @Test func restoredWALDatabaseWithoutSidecarsCanBeOpened() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try UsageStore(databaseURL: root.appendingPathComponent("original.sqlite"))
        try original.pool.write { db in
            try db.execute(sql: "INSERT INTO threads(thread_id, title) VALUES ('restored', '保留标题')")
        }
        let restoredURL = root.appendingPathComponent("restored.sqlite")
        let destination = try DatabaseQueue(path: restoredURL.path)
        try original.pool.backup(to: destination)
        try destination.close()
        // 独立备份只需要主文件；恢复不能依赖原始进程残留的 WAL/SHM。
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: restoredURL.path + suffix)
            if FileManager.default.fileExists(atPath: sidecar.path) { try FileManager.default.removeItem(at: sidecar) }
        }
        let restored = try UsageStore(databaseURL: restoredURL)
        let title = try restored.pool.read { try String.fetchOne($0, sql: "SELECT title FROM threads WHERE thread_id = 'restored'") }
        #expect(title == "保留标题")
    }

}
