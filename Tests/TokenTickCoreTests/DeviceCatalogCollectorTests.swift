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

    @Test func catalogIdentifiesSubagentsAndInheritsParentUpdatesAcrossPages() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try DatabaseQueue(path: root.appendingPathComponent("state_5.sqlite").path)
        try catalog.write { db in
            try db.execute(sql: """
                CREATE TABLE threads(id TEXT PRIMARY KEY,title TEXT,name TEXT,source TEXT,agent_nickname TEXT,project_id TEXT);
                CREATE TABLE projects(id TEXT PRIMARY KEY,name TEXT);
                INSERT INTO projects VALUES ('parent-project','Parent project'),('child-project','Child project');
                INSERT INTO threads VALUES
                    ('child','  ',NULL,'{"subagent":{"thread_spawn":{"parent_thread_id":"parent","agent_nickname":"Jason"}}}',NULL,'child-project'),
                    ('parent','Old title','Parent title','vscode',NULL,'parent-project');
                """)
        }
        let page = try DeviceCatalogPage.read(root: root, after: nil)
        let child = try #require(page.mappings.first { $0.threadID == "child" })
        let parent = try #require(page.mappings.first { $0.threadID == "parent" })
        #expect(child.title == nil && child.parentThreadID == "parent" && child.agentNickname == "Jason")
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        _ = try store.updateThreadMappings([child, .init(threadID: "nested", title: nil, projectName: nil, parentThreadID: "child")])
        #expect(try store.threadInfo(ids: ["child"])["child"]?.projectName == nil)
        _ = try store.updateThreadMappings([parent])
        let threads = try store.threadInfo(ids: ["child", "nested"])
        #expect(threads["child"]?.parentTitle == "Parent title" && threads["child"]?.agentNickname == "Jason")
        #expect(threads["nested"]?.projectName == "Parent project")
        try store.pool.write { db in
            try db.execute(sql: "INSERT INTO usage(thread_id,source_line,rollout_id,total_tokens,usage_date,source) VALUES ('child',1,'child',100,'2026-11-23','local')")
        }
        var query = UsageQuery(grouping: .project, timezone: "UTC")
        query.filters.search = "Parent title"
        #expect(try store.usageReport(query).rows.first?.group == "Parent project")
        #expect(try store.usageRecords(query).rows.first?.parentTitle == "Parent title")
        #expect(try store.updateThreadMappings([child, parent]) == 0)
        _ = try store.updateThreadMappings([.init(threadID: "parent", title: "Renamed", projectName: "Chat")])
        #expect(try store.threadInfo(ids: ["nested"])["nested"]?.projectName == "Chat")
        #expect(try store.usageRecords().rows.first?.parentTitle == "Renamed")
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
