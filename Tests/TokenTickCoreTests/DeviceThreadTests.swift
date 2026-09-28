import Foundation
import GRDB
import Testing
@testable import TokenTickCore

struct DeviceThreadTests {
    @Test(arguments: ["local", "remote"]) func owningSourceCanChangeAndClearProject(device: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        for project in ["First", "Second", nil] as [String?] {
            _ = try store.updateThreadMappings([ThreadMapping(threadID: "task", title: "Task", projectName: project)], device: device)
            #expect(try store.threadInfo(ids: ["task"], device: device)["task"]?.projectName == project)
        }
        _ = try store.updateThreadMappings([ThreadMapping(threadID: "task", title: "Stale", projectName: "First")], device: "later-device")
        #expect(try store.threadInfo(ids: ["task"], device: device)["task"]?.projectName == nil)
    }

    @Test func projectsStayWithTheirDeviceAndRetentionKeepsAllCollectedRows() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        let remote = RemoteDevice(name: "Remote", connection: .directory(path: "/fixture", bookmark: nil))
        for (device, title, project) in [("local", "Local task", "A"), (remote.id, "Remote task", "B")] {
            _ = try store.updateThreadMappings([ThreadMapping(threadID: "task", title: title, projectName: project)], device: device)
            try store.pool.write { db in
                try db.execute(sql: "INSERT INTO usage(device,source_line,rollout_id,thread_id,source,usage_date,total_tokens,pricing_source) VALUES (?,1,?,'task','local','2026-09-01',100,'{}')", arguments: [device, device])
            }
        }
        try store.recordFullDeviceManifest(remote)
        try store.recordDeviceCollectionComplete(remote)
        _ = try store.updateThreadMappings([], device: remote.id, catalogCheckpoint: (0, "next"))
        let projects = try store.usageReport(UsageQuery(grouping: .project, timezone: "UTC")).rows
        #expect(Set(projects.compactMap(\.group)) == ["A", "B"])
        #expect(projects.allSatisfy { $0.totalTokens == 100 })
        var taskQuery = UsageQuery(grouping: .thread, timezone: "UTC", sort: .name)
        #expect(try store.usageReport(taskQuery).rows.first?.totalTokens == 200)
        taskQuery.filters.device = .value(remote.id)
        #expect(try store.usageReport(taskQuery).rows.first?.totalTokens == 100)
        #expect(try store.usageRecords().rows.count == 2)
        #expect(try store.threadInfo(ids: ["task"], device: remote.id)["task"]?.title == "Remote task")
        let before = try store.pool.read { try String.fetchOne($0, sql: "SELECT group_concat(key || value) FROM app_metadata") }
        try store.removeDeviceData(device: remote.id, deleteUsage: false)
        let after = try store.pool.read { try String.fetchOne($0, sql: "SELECT group_concat(key || value) FROM app_metadata") }
        #expect(before == after)
        #expect(try store.usageRecords().rows.count == 2)
        #expect(try store.threadInfo(ids: ["task"], device: remote.id)["task"]?.projectName == "B")
        try store.removeDeviceData(device: remote.id, deleteUsage: true)
        #expect(try store.threadInfo(ids: ["task"], device: remote.id).isEmpty)
        #expect(try store.usageRecords().rows.count == 1)
        _ = try store.updateThreadMappings([ThreadMapping(threadID: "task", title: "Changed", projectName: "C")])
        #expect(try store.usageReport(UsageQuery(grouping: .project, timezone: "UTC")).rows.first?.group == "C")
    }
}
