import Foundation
import CoreServices
import GRDB
import Synchronization
import Testing
@testable import TokenTickCore

struct AutomaticSyncTests {
    @Test func eventsSelectChangedDirectoriesAndKeepMetadataSeparate() throws {
        let root = "/fixture"
        let file = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemModified)
        let directory = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemCreated)
        var changes = try #require(CodexLogChanges.events(root: root,
            paths: ["/fixture/sessions/2025/01/01/old.jsonl", "/fixture/sessions/2026/11/08", "/fixture/archived_sessions/task.jsonl"],
            flags: [file, directory, file]))
        #expect(changes.directories == ["sessions/2025/01/01", "sessions/2026/11/08", "archived_sessions"])
        let metadata = try #require(CodexLogChanges.events(root: root, paths: ["/fixture/state_5.sqlite-wal"], flags: [file]))
        #expect(metadata.directories == [])
        changes.merge(metadata)
        #expect(changes.directories?.count == 3)
        #expect(CodexLogChanges.events(root: root, paths: ["/fixture/state_5.sqlite-shm", "/fixture/sessions-other/file"], flags: [file, file]) == nil)
        #expect(CodexLogChanges.events(root: "/private/var/fixture", paths: ["/private/var/fixture/sessions/2026/11/08/log.jsonl"],
            flags: [file])?.directories == ["sessions/2026/11/08"])
        for flag in [kFSEventStreamEventFlagMustScanSubDirs, kFSEventStreamEventFlagRootChanged,
                     kFSEventStreamEventFlagUserDropped, kFSEventStreamEventFlagKernelDropped] {
            let lost = try #require(CodexLogChanges.events(root: root, paths: ["/fixture/sessions"], flags: [FSEventStreamEventFlags(flag)]))
            #expect(lost.directories == nil)
            var pending = changes
            pending.merge(lost)
            pending.merge(metadata)
            #expect(pending.directories == nil)
        }
    }

    @Test func backgroundScansWaitFiveMinutesAndActivationRecalculatesDelay() {
        let start = Date(timeIntervalSince1970: 1_000)
        var schedule = AutomaticSyncSchedule(now: start)
        schedule.applicationActive(false)
        #expect(schedule.takeDueScope(now: start) == .all)
        schedule.logsChanged(now: start.addingTimeInterval(1))
        #expect(schedule.takeDueScope(now: start.addingTimeInterval(299)) == nil)
        #expect(schedule.takeDueScope(now: start.addingTimeInterval(300)) == .all)
        schedule.logsChanged(now: start.addingTimeInterval(301))
        schedule.applicationActive(true)
        #expect(schedule.takeDueScope(now: start.addingTimeInterval(359)) == nil)
        #expect(schedule.takeDueScope(now: start.addingTimeInterval(360)) == .local)
        schedule.cancelled(now: start.addingTimeInterval(400))
        schedule.applicationActive(false)
        schedule.applicationActive(true)
        schedule.logsChanged(now: start.addingTimeInterval(401))
        #expect(schedule.takeDueScope(now: start.addingTimeInterval(459)) == nil)
        #expect(schedule.takeDueScope(now: start.addingTimeInterval(460)) == .local)
    }

    @Test func freshLogsDeferRemoteUntilQuietOrThirtyMinuteDeadline() {
        let start = Date(timeIntervalSince1970: 1000)
        var schedule = AutomaticSyncSchedule(now: start)
        schedule.started(.all, now: start)
        schedule.acceptedLog(observedAt: start.addingTimeInterval(200), now: start.addingTimeInterval(200))
        #expect(schedule.takeDueScope(now: start.addingTimeInterval(300)) == nil)
        #expect(schedule.takeDueScope(now: start.addingTimeInterval(499)) == nil)
        #expect(schedule.takeDueScope(now: start.addingTimeInterval(500)) == .remote)
        schedule = AutomaticSyncSchedule(now: start)
        schedule.started(.all, now: start)
        for second in stride(from: 200, through: 1600, by: 200) {
            let now = start.addingTimeInterval(Double(second))
            schedule.acceptedLog(observedAt: now, now: now)
            #expect(schedule.takeDueScope(now: now) == nil)
        }
        #expect(schedule.takeDueScope(now: start.addingTimeInterval(1800)) == .remote)
    }

    @Test func startupAndBurstsStayThrottledWithoutPeriodicLogScans() {
        let start = Date(timeIntervalSince1970: 1_000)
        var schedule = AutomaticSyncSchedule(now: start)
        #expect(schedule.takeDueScope(now: start) == .all)
        for second in 1...59 { schedule.logsChanged(now: start.addingTimeInterval(Double(second))) }
        #expect(schedule.takeDueScope(now: start.addingTimeInterval(59)) == nil)
        #expect(schedule.takeDueScope(now: start.addingTimeInterval(60)) == .local)
        #expect(schedule.takeDueScope(now: start.addingTimeInterval(69)) == nil)
        #expect(schedule.takeDueScope(now: start.addingTimeInterval(70)) == nil)
        schedule.logsChanged(now: start.addingTimeInterval(90))
        #expect(schedule.takeDueScope(now: start.addingTimeInterval(90)) == nil)
        #expect(schedule.takeDueScope(now: start.addingTimeInterval(120)) == .local)
        #expect(schedule.takeDueScope(now: start.addingTimeInterval(300)) == .remote)
        // A long idle or sleeping interval does not schedule another log scan.
        #expect(schedule.takeDueScope(now: start.addingTimeInterval(10_000)) == .remote)
        #expect(schedule.takeDueScope(now: start.addingTimeInterval(10_000)) == nil)
    }

    @Test func eventsDuringWorkAreRetainedAndCancellationHasQuietPeriod() {
        let start = Date(timeIntervalSince1970: 1_000)
        var schedule = AutomaticSyncSchedule(now: start)
        schedule.started(.all, now: start)
        schedule.logsChanged(now: start.addingTimeInterval(15))
        schedule.logsChanged(now: start.addingTimeInterval(50))
        #expect(schedule.nextCheck == start.addingTimeInterval(60))
        #expect(schedule.takeDueScope(now: start.addingTimeInterval(59)) == nil)
        #expect(schedule.takeDueScope(now: start.addingTimeInterval(60)) == .local)
        schedule.cancelled(now: start.addingTimeInterval(61))
        schedule.logsChanged(now: start.addingTimeInterval(62))
        #expect(schedule.takeDueScope(now: start.addingTimeInterval(120)) == nil)
        #expect(schedule.takeDueScope(now: start.addingTimeInterval(121)) == .local)
        schedule.started(.api, now: start.addingTimeInterval(200))
        #expect(schedule.takeDueScope(now: start.addingTimeInterval(300)) == nil)
        #expect(schedule.takeDueScope(now: start.addingTimeInterval(500)) == .remote)
    }

    @Test func watcherFailureStopsAutomaticLogsWithoutStoppingAPI() {
        let start = Date(timeIntervalSince1970: 1_000)
        var schedule = AutomaticSyncSchedule(now: start)
        schedule.watcherAvailable(false)
        #expect(schedule.takeDueScope(now: start) == .remote)
        schedule.logsChanged(now: start.addingTimeInterval(1))
        #expect(schedule.takeDueScope(now: start.addingTimeInterval(59)) == nil)
        #expect(schedule.takeDueScope(now: start.addingTimeInterval(60)) == nil)
        #expect(schedule.takeDueScope(now: start.addingTimeInterval(121)) == nil)
        for second in stride(from: 300, through: 1800, by: 300) {
            #expect(schedule.takeDueScope(now: start.addingTimeInterval(Double(second))) == .remote)
        }
        #expect(schedule.takeDueScope(now: start.addingTimeInterval(1861)) == nil)
    }

    @Test func openingCurrentStoreAndReadingFactsDoesNotWaitForScanLock() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("usage.sqlite")
        let store = try UsageStore(databaseURL: url)
        try store.pool.write { db in
            try db.execute(sql: "INSERT INTO usage(source_line,rollout_id, usage_date, total_tokens, source, pricing_source) VALUES (1,'a', '2026-09-09', 9, 'local', '{}')")
        }
        try FileWriteLock(url: url.appendingPathExtension("write.lock")).withLock {
            let reopened = try UsageStore(databaseURL: url)
            let report = try reopened.usageReport(UsageQuery(grouping: .total, timezone: "UTC"))
            #expect(report.rows.first?.totalTokens == 9)
            #expect(try reopened.tableCounts()["statistics"] == 0)
        }
    }

    @Test func cancelledWriterDoesNotRunAfterWaitingForAnotherOwner() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let lock = FileWriteLock(url: root.appendingPathComponent("write.lock"))
        let ready = DispatchSemaphore(value: 0)
        enum Unexpected: Error { case acquired }
        let waiter = try lock.withLock {
            let task = Task.detached {
                ready.signal()
                try lock.withLock { throw Unexpected.acquired }
            }
            #expect(ready.wait(timeout: .now() + 2) == .success)
            Thread.sleep(forTimeInterval: 0.1)
            task.cancel()
            return task
        }
        do {
            try await waiter.value
            Issue.record("A cancelled writer must not execute the protected operation.")
        } catch is CancellationError {} catch { Issue.record("Cancellation returned an unexpected error: \(error)") }
    }

    @Test func nativeFileEventsNoticeAppendArchiveAndNewDirectories() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let events = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let watcher = try CodexLogWatcher(codexHome: root) { _ in events.continuation.yield(()) }
        defer { events.continuation.finish(); withExtendedLifetime(watcher) {} }
        let file = root.appendingPathComponent("sessions/new/day/rollout-test.jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("first\n".utf8).write(to: file)
        try await expectEvent(events.stream)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("second\n".utf8)); try handle.close()
        try await expectEvent(events.stream)
        let archive = root.appendingPathComponent("archived_sessions")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: file, to: archive.appendingPathComponent(file.lastPathComponent))
        try await expectEvent(events.stream)
    }

    @Test(arguments: ["state_5", "logs_2"])
    func sqliteSharedMemoryDoesNotTriggerScanningButDatabaseAndWALDo(name: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = ["\(name).sqlite-shm", "\(name).sqlite-wal", "\(name).sqlite"].map { root.appendingPathComponent($0) }
        for file in files { try Data("initial".utf8).write(to: file) }
        let count = Mutex(0)
        let watcher = try CodexLogWatcher(codexHome: root) { _ in count.withLock { $0 += 1 } }
        defer { withExtendedLifetime(watcher) {} }
        // Drain creation events coalesced at the root before observing updates to existing files.
        try await Task.sleep(for: .seconds(2))
        for (index, file) in files.enumerated() {
            count.withLock { $0 = 0 }
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd(); try handle.write(contentsOf: Data("update".utf8)); try handle.close()
            if index == 0 {
                try await Task.sleep(for: .seconds(2))
                #expect(count.withLock { $0 } == 0, "Shared-memory changes must not cause read-only scans to trigger themselves.")
            } else {
                let deadline = ContinuousClock.now.advanced(by: .seconds(8))
                while count.withLock({ $0 }) == 0, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(100))
                }
                #expect(count.withLock { $0 } > 0, "Database and WAL changes must still trigger task mapping updates.")
            }
        }
    }

    private func expectEvent(_ stream: AsyncStream<Void>) async throws {
        let received = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask { for await _ in stream { return true }; return false }
            group.addTask { try await Task.sleep(for: .seconds(8)); return false }
            let result = try #require(try await group.next())
            group.cancelAll()
            return result
        }
        #expect(received, "FSEvents must report creation, append, or archive events; a timeout is not success.")
    }
}
