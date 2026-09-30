import Foundation
import Testing
@testable import TokenTickCore

struct CollectionSchedulerTests {
    private actor Activity {
        var active = Set<String>()
        var peak = 0
        var calls = 0
        func start(_ key: String) {
            #expect(active.insert(key).inserted)
            peak = max(peak, active.count)
            calls += 1
        }
        func end(_ key: String) { active.remove(key) }
    }

    @Test func sourcesShareCapacityAndEveryRequestRuns() async throws {
        let scheduler = CollectionScheduler()
        let activity = Activity()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for key in ["local", "remote-a", "local", "remote-b", "remote-a"] {
                group.addTask {
                    _ = try await scheduler.run(key: key) {
                        await activity.start(key)
                        try await Task.sleep(for: .milliseconds(30))
                        await activity.end(key)
                        return DeviceSyncResult(deviceID: key, root: "", scan: nil, finishedAt: Date(), metadataRefreshed: false)
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(await activity.calls == 5)
        #expect(await activity.peak == 2)
    }

    @Test func cancellationReleasesQueuedRequestWithoutRunningIt() async throws {
        let scheduler = CollectionScheduler()
        let activity = Activity()
        let running = Task {
            try await scheduler.run(key: "local") {
                await activity.start("local")
                try await Task.sleep(for: .seconds(30))
                return DeviceSyncResult(deviceID: "local", root: "", scan: nil, finishedAt: Date(), metadataRefreshed: false)
            }
        }
        while await activity.calls == 0 { await Task.yield() }
        let queued = Task {
            try await scheduler.run(key: "local") {
                Issue.record("A cancelled queued request must not run")
                return DeviceSyncResult(deviceID: "local", root: "", scan: nil, finishedAt: Date(), metadataRefreshed: false)
            }
        }
        await Task.yield()
        queued.cancel()
        await #expect(throws: CancellationError.self) { try await queued.value }
        running.cancel()
        await #expect(throws: CancellationError.self) { try await running.value }
        let next = try await scheduler.run(key: "local") {
            DeviceSyncResult(deviceID: "local", root: "", scan: nil, finishedAt: Date(), metadataRefreshed: false)
        }
        #expect(next.deviceID == "local")
    }
}
