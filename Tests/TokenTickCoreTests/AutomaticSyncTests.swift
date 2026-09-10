import Foundation
import GRDB
import Synchronization
import Testing
@testable import TokenTickCore

struct AutomaticSyncTests {
    @Test func startupBurstsPeriodicChecksAndRecoveryStayThrottled() {
        let start = Date(timeIntervalSince1970: 1_000)
        var schedule = AutomaticSyncSchedule(now: start)
        #expect(schedule.takeDueScope(now: start) == .all)
        for second in 1...9 { schedule.logsChanged(now: start.addingTimeInterval(Double(second))) }
        #expect(schedule.takeDueScope(now: start.addingTimeInterval(9)) == nil)
        #expect(schedule.takeDueScope(now: start.addingTimeInterval(10)) == .local)
        #expect(schedule.takeDueScope(now: start.addingTimeInterval(69)) == nil)
        #expect(schedule.takeDueScope(now: start.addingTimeInterval(70)) == nil)
        schedule.recovered(now: start.addingTimeInterval(90))
        #expect(schedule.takeDueScope(now: start.addingTimeInterval(90)) == .local)
        #expect(schedule.takeDueScope(now: start.addingTimeInterval(300)) == .remote)
        // 睡眠期间漏过多个周期，恢复只合并为一次，不重放所有错过的计时器。
        schedule.recovered(now: start.addingTimeInterval(10_000))
        #expect(schedule.takeDueScope(now: start.addingTimeInterval(10_000)) == .all)
        #expect(schedule.takeDueScope(now: start.addingTimeInterval(10_000)) == nil)
    }

    @Test func eventsDuringWorkAreRetainedAndCancellationHasQuietPeriod() {
        let start = Date(timeIntervalSince1970: 1_000)
        var schedule = AutomaticSyncSchedule(now: start)
        schedule.started(.all, now: start)
        schedule.logsChanged(now: start.addingTimeInterval(15))
        schedule.logsChanged(now: start.addingTimeInterval(50))
        #expect(schedule.nextCheck == start.addingTimeInterval(17))
        #expect(schedule.takeDueScope(now: start.addingTimeInterval(55)) == .local)
        schedule.cancelled(now: start.addingTimeInterval(56))
        schedule.logsChanged(now: start.addingTimeInterval(57))
        #expect(schedule.takeDueScope(now: start.addingTimeInterval(115)) == nil)
        #expect(schedule.takeDueScope(now: start.addingTimeInterval(116)) == .local)
        schedule.started(.api, now: start.addingTimeInterval(200))
        #expect(schedule.takeDueScope(now: start.addingTimeInterval(300)) == nil)
        #expect(schedule.takeDueScope(now: start.addingTimeInterval(500)) == .remote)
    }

    @Test func watcherFailureEnablesShortFallbackAndRecoveryRestoresLongInterval() {
        let start = Date(timeIntervalSince1970: 1_000)
        var schedule = AutomaticSyncSchedule(now: start)
        schedule.watcherAvailable(false, now: start)
        schedule.started(.all, now: start)
        #expect(schedule.takeDueScope(now: start.addingTimeInterval(59)) == nil)
        #expect(schedule.takeDueScope(now: start.addingTimeInterval(60)) == .local)
        schedule.watcherAvailable(true, now: start.addingTimeInterval(61))
        schedule.started(.local, now: start.addingTimeInterval(61))
        #expect(schedule.takeDueScope(now: start.addingTimeInterval(121)) == nil)
        for second in stride(from: 300, through: 1800, by: 300) {
            #expect(schedule.takeDueScope(now: start.addingTimeInterval(Double(second))) == .remote)
        }
        #expect(schedule.takeDueScope(now: start.addingTimeInterval(1861)) == .local)
    }

    @Test func openingCurrentStoreAndReadingFactsDoesNotWaitForScanLock() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("usage.sqlite")
        let store = try UsageStore(databaseURL: url)
        try store.pool.write { db in
            try db.execute(sql: "INSERT INTO usage(dedup_key, usage_date, total_tokens, source, evidence_json) VALUES ('a', '2026-09-09', 9, 'local', '{}')")
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
            Issue.record("取消的写者不应执行受保护操作。")
        } catch is CancellationError {} catch { Issue.record("取消返回了错误类型：\(error)") }
    }

    @Test func nativeFileEventsNoticeAppendArchiveAndNewDirectories() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let events = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let watcher = try CodexLogWatcher(codexHome: root) { events.continuation.yield(()) }
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

    @Test func sqliteSharedMemoryDoesNotTriggerScanningButDatabaseAndWALDo() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = ["state_5.sqlite-shm", "state_5.sqlite-wal", "state_5.sqlite"].map { root.appendingPathComponent($0) }
        for file in files { try Data("initial".utf8).write(to: file) }
        let count = Mutex(0)
        let watcher = try CodexLogWatcher(codexHome: root) { count.withLock { $0 += 1 } }
        defer { withExtendedLifetime(watcher) {} }
        // 先排空建目录和文件时可能合并到根目录的事件，再观察现有文件的更新。
        try await Task.sleep(for: .seconds(2))
        for (index, file) in files.enumerated() {
            count.withLock { $0 = 0 }
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd(); try handle.write(contentsOf: Data("update".utf8)); try handle.close()
            if index == 0 {
                try await Task.sleep(for: .seconds(2))
                #expect(count.withLock { $0 } == 0, "共享内存变化不能让只读扫描触发自身。")
            } else {
                let deadline = ContinuousClock.now.advanced(by: .seconds(8))
                while count.withLock({ $0 }) == 0, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(100))
                }
                #expect(count.withLock { $0 } > 0, "主库及 WAL 变化仍须通知任务映射更新。")
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
        #expect(received, "FSEvents 应通知新增、追加或归档，超时不能当成成功。")
    }
}
