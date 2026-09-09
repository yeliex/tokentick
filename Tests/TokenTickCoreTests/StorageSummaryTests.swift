import Foundation
import GRDB
import Testing
@testable import TokenTickCore

struct StorageSummaryTests {
    @Test func reportsLiveFilesWithoutCreatingBackupsOrChangingFacts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        let before = try store.tableCounts()
        let summary = try store.storageSummary()
        func bytes(_ suffix: String) throws -> Int64 {
            let path = store.databaseURL.path + suffix
            if !FileManager.default.fileExists(atPath: path) { return 0 }
            return try Int64(URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey]).fileSize!)
        }
        #expect(summary.databaseBytes == (try bytes("")))
        #expect(summary.walBytes == (try bytes("-wal")))
        #expect(summary.sharedMemoryBytes == (try bytes("-shm")))
        #expect(summary.liveBytes == summary.databaseBytes + summary.walBytes + summary.sharedMemoryBytes)
        #expect(summary.backupCount == 0 && summary.backupBytes == 0 && summary.recentBackups.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: summary.backupDirectory.path))
        #expect(try store.tableCounts() == before)
    }

    @Test func boundsRecentMetadataAndExcludesUnownedFilesAndSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        let backups = root.appendingPathComponent("Backups")
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: false)
        for index in 0..<24 {
            let url = backups.appendingPathComponent(String(format: "before-migration-%02d.sqlite", index))
            // 内容故意不是 SQLite：容量查询只读元数据，不打开备份或迁移它。
            try Data(repeating: UInt8(index), count: index + 1).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(index))], ofItemAtPath: url.path)
        }
        let other = backups.appendingPathComponent("other.sqlite")
        try Data(repeating: 1, count: 100).write(to: other)
        try Data([1]).write(to: backups.appendingPathComponent("before-migration-incomplete.sqlite-wal"))
        try FileManager.default.createSymbolicLink(at: backups.appendingPathComponent("before-migration-link.sqlite"), withDestinationURL: other)
        try FileManager.default.createDirectory(at: backups.appendingPathComponent("before-migration-directory.sqlite"), withIntermediateDirectories: false)
        let summary = try store.storageSummary()
        #expect(summary.backupCount == 24 && summary.backupBytes == 300)
        #expect(summary.recentBackups.count == 20)
        #expect(summary.recentBackups.first?.id == "before-migration-23.sqlite")
        #expect(summary.recentBackups.last?.id == "before-migration-04.sqlite")
        #expect(summary.recentBackups.first?.bytes == 24)
        #expect(try Data(contentsOf: summary.recentBackups.first!.url) == Data(repeating: 23, count: 24))
    }

    @Test func existingMigrationSnapshotIsVisibleWithoutOpeningIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let url = root.appendingPathComponent("usage.sqlite")
        let old = try DatabaseQueue(path: url.path)
        try old.write { db in try db.execute(sql: "CREATE TABLE retained(value TEXT); INSERT INTO retained VALUES ('history')") }
        try old.close()
        let store = try UsageStore(databaseURL: url)
        let summary = try store.storageSummary()
        #expect(summary.backupCount == 1 && summary.backupBytes > 0)
        let backup = try #require(summary.recentBackups.first)
        var configuration = Configuration(); configuration.readonly = true
        let saved = try DatabaseQueue(path: backup.url.path, configuration: configuration)
        #expect(try saved.read { db in try String.fetchOne(db, sql: "SELECT value FROM retained") } == "history")
        try saved.close()
    }
}
