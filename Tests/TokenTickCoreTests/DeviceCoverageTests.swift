import Foundation
import Testing
@testable import TokenTickCore

struct DeviceCoverageTests {
    @Test func manifestPlanExpiresAndFollowsSourceRevision() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        var device = RemoteDevice(name: "History", connection: .directory(path: root.path, bookmark: nil))
        let now = Date(timeIntervalSince1970: 1_790_467_200)
        #expect(try store.incrementalManifestDirectories(device: device, root: root.path, now: now) == nil)
        try store.recordFullDeviceManifest(device, at: now)
        let reopened = try UsageStore(databaseURL: store.databaseURL)
        let directories = try #require(try reopened.incrementalManifestDirectories(device: device, root: root.path, now: now))
        #expect(directories.count == 9 && directories.allSatisfy { $0.hasPrefix("sessions/") })
        #expect(try reopened.incrementalManifestDirectories(device: device, root: root.path, now: now.addingTimeInterval(1_800)) == nil)
        #expect(try reopened.incrementalManifestDirectories(device: device, root: root.path, now: now.addingTimeInterval(-1)) == nil)
        device.edit(name: "History", connection: .directory(path: "/different", bookmark: nil), enabled: true)
        #expect(try reopened.incrementalManifestDirectories(device: device, root: root.path, now: now) == nil)
    }

    @Test func completionBelongsToDatabaseAndSourceRevision() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        let configurations = DeviceConfigurationStore(directory: root)
        let first = RemoteDevice(name: "First", connection: .directory(path: "/first", bookmark: nil))
        let second = RemoteDevice(name: "Paused", connection: .directory(path: "/second", bookmark: nil), enabled: false)
        var configuration = try configurations.update { $0.devices = [first, second] }
        #expect(try store.deviceCoverageGaps(configuration) == [first.id, second.id])
        try store.recordDeviceCollectionComplete(first)
        let completedAt = try #require(try store.deviceCollectionDates(configuration)[first.id])
        #expect(try store.deviceCoverageGaps(configuration) == [second.id])
        let reopened = try UsageStore(databaseURL: store.databaseURL)
        #expect(try reopened.deviceCollectionDates(configuration)[first.id] == completedAt)
        #expect(try reopened.deviceCoverageGaps(configuration) == [second.id])
        var changed = first
        changed.edit(name: "Renamed", connection: first.connection, enabled: true)
        configuration.devices[0] = changed
        #expect(try store.deviceCoverageGaps(configuration) == [second.id])
        #expect(try store.deviceCollectionDates(configuration)[first.id] == completedAt)
        changed.edit(name: "Renamed", connection: .directory(path: "/different", bookmark: nil), enabled: true)
        configuration.devices[0] = changed
        #expect(try store.deviceCoverageGaps(configuration) == [first.id, second.id])
        #expect(try store.deviceCollectionDates(configuration).isEmpty)
        let fresh = try UsageStore(databaseURL: root.appendingPathComponent("rebuilt.sqlite"))
        #expect(try fresh.deviceCoverageGaps(configurations.load()) == [first.id, second.id])
        #expect(try configurations.load().devices.map(\.id) == [first.id, second.id])
    }

    @Test func retainedHistoryKeepsCompletionWhileDeletedHistoryLosesIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        let device = RemoteDevice(name: "History", connection: .directory(path: "/fixture", bookmark: nil))
        var configuration = DeviceConfiguration()
        configuration.devices = [device]
        try store.recordDeviceCollectionComplete(device)
        try configuration.remove(id: device.id, keepHistory: true)
        try store.removeDeviceData(device: device.id, deleteUsage: false)
        #expect(try store.deviceCoverageGaps(configuration).isEmpty)
        try store.removeDeviceData(device: device.id, deleteUsage: true)
        #expect(try store.deviceCoverageGaps(configuration) == [device.id])
    }
}
