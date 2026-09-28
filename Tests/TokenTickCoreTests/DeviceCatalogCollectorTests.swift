import Foundation
import GRDB
import Testing
@testable import TokenTickCore

struct DeviceCatalogCollectorTests {
    @Test func boundedPagesResumeAcrossRestartAndRetentionKeepsCheckpoint() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("usage.sqlite")
        let store = try UsageStore(databaseURL: database)
        let device = RemoteDevice(name: "Fixture", connection: .directory(path: "/fixture", bookmark: nil))
        let source = Source(database: database)
        var report = ScanReport()
        try await DeviceCatalogCollector(store: store, device: device, maximumPages: 1)
            .collect(source: source, report: &report)
        #expect(report.pendingMetadata && report.refreshedThreads == 1)
        #expect(try store.deviceCatalogCursor(device: device.id, sourceRevision: 0) == "a")
        #expect(try store.deviceCatalogCursor(device: device.id, sourceRevision: 1) == nil)
        let reopened = try UsageStore(databaseURL: database)
        var resumed = ScanReport()
        try await DeviceCatalogCollector(store: reopened, device: device, maximumPages: 1)
            .collect(source: source, report: &resumed)
        #expect(!resumed.pendingMetadata && resumed.refreshedThreads == 1)
        #expect(try reopened.deviceCatalogCursor(device: device.id, sourceRevision: 0) == nil)
        #expect(try reopened.threadInfo(ids: ["a", "b"]).count == 2)
        var nextRefresh = ScanReport()
        try await DeviceCatalogCollector(store: reopened, device: device, maximumPages: 1)
            .collect(source: source, report: &nextRefresh)
        try reopened.removeDeviceData(device: device.id, deleteUsage: false)
        #expect(try reopened.deviceCatalogCursor(device: device.id, sourceRevision: 0) == "a")
        #expect(try reopened.threadInfo(ids: ["a", "b"]).count == 2)
    }

    @Test func checkpointFailureRollsBackMetadataAndCanRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        let device = RemoteDevice(name: "Fixture", connection: .directory(path: "/fixture", bookmark: nil))
        try await store.pool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_catalog_checkpoint BEFORE INSERT ON app_metadata
                WHEN NEW.key LIKE 'device_catalog_cursor:%'
                BEGIN SELECT RAISE(ABORT,'injected checkpoint failure'); END
                """)
        }
        let collector = DeviceCatalogCollector(store: store, device: device, maximumPages: 1)
        let source = Source(database: store.databaseURL)
        var report = ScanReport()
        await #expect(throws: (any Error).self) { try await collector.collect(source: source, report: &report) }
        #expect(try store.threadInfo(ids: ["a"]).isEmpty)
        #expect(try store.deviceCatalogCursor(device: device.id, sourceRevision: 0) == nil)
        try await store.pool.write { try $0.execute(sql: "DROP TRIGGER reject_catalog_checkpoint") }
        try await collector.collect(source: source, report: &report)
        #expect(report.pendingMetadata && report.refreshedThreads == 1)
    }

    @Test func localCatalogReusesDesktopSnapshotOnlyWithinOnePass() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try DatabaseQueue(path: root.appendingPathComponent("state_5.sqlite").path)
        try database.write { db in
            try db.execute(sql: "CREATE TABLE threads(id TEXT PRIMARY KEY,title TEXT,cwd TEXT)")
            for index in 0..<513 {
                try db.execute(sql: "INSERT INTO threads VALUES(?, 'Title', '/project')", arguments: [String(format: "%04d", index)])
            }
        }
        let desktop = root.appendingPathComponent(".codex-global-state.json")
        let first = #"{"local-projects":{"p":{"name":"First","rootPaths":["/project"]}}}"#
        try Data(first.utf8).write(to: desktop)
        let source = try LocalFileSource(root: root)
        let page = try source.catalog(after: nil)
        #expect(page.entries.count == 512)
        try Data(first.replacingOccurrences(of: "First", with: "Second").utf8).write(to: desktop)
        let last = try source.catalog(after: page.next)
        #expect(last.mappings.first?.projectName == "First")
        #expect(try LocalFileSource(root: root).catalog(after: nil).mappings.first?.projectName == "Second")
    }

    private struct Source: DeviceFileSource {
        let database: URL
        func probe() -> String { "/fixture" }
        func manifest() -> DeviceSourceManifest { .init(root: "/fixture", files: []) }
        func read(_ file: DeviceSourceFile, offset: UInt64, count: Int) throws -> Data { throw DeviceSourceFailure.unsupported }
        func catalog(after: String?) throws -> DeviceCatalogPage {
            try FileWriteLock(url: database.appendingPathExtension("write.lock")).withLock(nonBlocking: true) {}
            let id = after == nil ? "a" : "b"
            return DeviceCatalogPage(entries: [.init(id: id, title: "Title \(id)", projectName: "Fixture", cwd: nil)],
                                     desktop: nil, next: after == nil ? "a" : nil, available: true)
        }
    }
}
