import Foundation
import GRDB
import Testing
@testable import TokenTickCore

struct DeviceUsageScannerTests {
    @Test func remoteCopyDeduplicatesThenReadsOnlyItsNewTail() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let sessions = fixture.root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let path = sessions.appendingPathComponent("rollout-2026-09-09T00-00-00-00000000-0000-0000-0000-000000000001.jsonl")
        let bytes = Data((header + record(1)).utf8)
        try bytes.write(to: path)
        _ = try await LocalUsageScanner(store: fixture.store).scan(codexHome: fixture.root)
        let source = Source(data: bytes, database: fixture.store.databaseURL)
        let scanner = UsageScanner(store: fixture.store, device: fixture.device, priority: DevicePriority())
        let first = try await scanner.scan(source: source)
        #expect(first.duplicateRequests == 1)
        #expect(try fixture.store.usageRecords().rows.map(\.device) == ["local"])
        await source.append(Data(record(2).utf8))
        let tail = try await scanner.scan(source: source)
        #expect(tail.insertedRequests == 1 && tail.duplicateRequests == 0)
        #expect(tail.scannedBytes == UInt64(record(2).utf8.count))
        #expect(try fixture.store.usageRecords().rows.count == 2)
        #expect(try await scanner.scan(source: source).unchangedFiles == 1)
    }

    @Test func fileBudgetDoesNotCountUnchangedFilesAgainstOlderHistory() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let log = header + record(1)
        let source = Source(data: Data(log.utf8), database: fixture.store.databaseURL)
        await source.setOlderLog(Data(log.replacingOccurrences(of: "00000000-0000-0000-0000-000000000001",
                                                               with: "00000000-0000-0000-0000-000000000002")
            .replacingOccurrences(of: "turn-1", with: "older-turn").utf8))
        let scanner = UsageScanner(store: fixture.store, device: fixture.device, priority: DevicePriority(), maximumFilesPerPass: 1)
        try fixture.store.recordFullDeviceManifest(fixture.device)
        let first = try await scanner.scan(source: source)
        #expect(first.scannedFiles == 1 && first.pendingFiles == 1)
        #expect(try fixture.store.incrementalManifestDirectories(device: fixture.device, root: "/synthetic") == nil)
        let second = try await scanner.scan(source: source)
        #expect(second.unchangedFiles == 1 && second.scannedFiles == 1 && second.pendingFiles == 0)
        let directories = try #require(try fixture.store.incrementalManifestDirectories(device: fixture.device, root: "/synthetic"))
        #expect(directories.contains("sessions") && directories.contains("archived_sessions"))
        #expect(try fixture.store.usageRecords().rows.count == 2)
        let third = try await scanner.scan(source: source)
        #expect(third.unchangedFiles == 2 && third.scannedBytes == 0)
    }

    @Test func boundedPassResumesHistoryWithoutDuplicates() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let source = Source(data: Data((header + (1...513).map(record).joined()).utf8), database: fixture.store.databaseURL)
        let scanner = UsageScanner(store: fixture.store, device: fixture.device, priority: DevicePriority(), maximumBytesPerPass: 1)
        let first = try await scanner.scan(source: source)
        #expect(first.pendingFiles == 1 && first.issueCount == 0)
        #expect(first.insertedRequests == 510 && first.scannedBytes > 0)
        let cursor = try #require(try fixture.store.scanCursor(rolloutID: "00000000-0000-0000-0000-000000000001", device: fixture.device.id))
        #expect(!cursor.file.completed)
        let second = try await scanner.scan(source: source)
        #expect(second.pendingFiles == 0 && second.insertedRequests == 3)
        #expect(try fixture.store.usageReport(UsageQuery(grouping: .total)).rows.first?.records == 513)
        #expect(try await scanner.scan(source: source).unchangedFiles == 1)
    }

    @Test func interruptedReadResumesCommittedBatchWithoutDuplicates() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let padding = "{\"type\":\"response_item\",\"payload\":\"" + String(repeating: "x", count: 2_100_000) + "\"}\n"
        let data = header + (1...512).map(record).joined() + padding + record(513)
        let source = Source(data: Data(data.utf8), database: fixture.store.databaseURL)
        await source.failReads(at: 1_048_576)
        let scanner = UsageScanner(store: fixture.store, device: fixture.device, priority: DevicePriority())
        let interrupted = try await scanner.scan(source: source)
        #expect(interrupted.diagnosticCounts["device_read"] == 1)
        #expect(interrupted.diagnosticCounts["device_parse"] == nil)
        #expect(interrupted.insertedRequests == 510)
        let cursor = try #require(try fixture.store.scanCursor(rolloutID: "00000000-0000-0000-0000-000000000001", device: fixture.device.id))
        #expect(!cursor.file.completed && cursor.offset > 0)
        await source.failReads(at: nil)
        let recovered = try await scanner.scan(source: source)
        #expect(recovered.issues.isEmpty)
        #expect(recovered.insertedRequests == 3)
        #expect(try fixture.store.usageReport(UsageQuery(grouping: .total)).rows.first?.records == 513)
        #expect(try await scanner.scan(source: source).unchangedFiles == 1)
    }

    @Test func verifiesCopiesOnceAndStopsConflictingCopies() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let bytes = Data((header + record(1)).utf8)
        let source = Source(data: bytes, database: fixture.store.databaseURL)
        await source.setDuplicate(bytes)
        let scanner = UsageScanner(store: fixture.store, device: fixture.device, priority: DevicePriority())
        #expect(try await scanner.scan(source: source).insertedRequests == 1)
        await source.resetTransferred()
        #expect(try await scanner.scan(source: source).unchangedFiles == 1)
        #expect(await source.transferred == 0)
        await source.setDuplicate(Data((header + record(1) + record(2)).utf8))
        let conflict = try await scanner.scan(source: source)
        #expect(conflict.issueCount == 1)
        #expect(conflict.scannedFiles == 0)
        #expect(try fixture.store.usageRecords().rows.count == 1)
    }

    @Test func readsOnlyNewTailAndCheckpointsOutsideNetworkWaits() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let padding = "{\"timestamp\":\"2026-09-09T00:00:00Z\",\"type\":\"response_item\",\"payload\":\"" + String(repeating: "x", count: 2_100_000) + "\"}\n"
        let source = Source(data: Data((header + padding + record(1)).utf8), database: fixture.store.databaseURL)
        let scanner = UsageScanner(store: fixture.store, device: fixture.device, priority: DevicePriority())
        let first = try await scanner.scan(source: source)
        #expect(first.issues.isEmpty, "\(first.issues)")
        #expect(first.insertedRequests == 1)
        await source.resetTransferred()
        #expect(try await scanner.scan(source: source).unchangedFiles == 1)
        #expect(await source.transferred == 0)
        await source.append(Data(record(2).utf8))
        #expect(try await scanner.scan(source: source).insertedRequests == 1)
        #expect(await source.transferred < 20_000)
        let rows = try fixture.store.usageRecords().rows
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.device == fixture.device.id && $0.accountID == nil })
        let next = record(3)
        let midpoint = next.index(next.startIndex, offsetBy: next.count / 2)
        await source.append(Data(next[..<midpoint].utf8))
        #expect(try await scanner.scan(source: source).insertedRequests == 0)
        await source.append(Data(next[midpoint...].utf8))
        #expect(try await scanner.scan(source: source).insertedRequests == 1)
        #expect(try fixture.store.usageRecords().rows.count == 3)
    }

    @Test func priorityIsIndependentOfScanOrderAndDoesNotChangeTotal() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let newer = RemoteDevice(name: "Newer", connection: .directory(path: "/synthetic", bookmark: nil))
        let devices = [fixture.device, newer].sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        let priority = DevicePriority(devices: devices)
        let source = Source(data: Data((header + record(1)).utf8), database: fixture.store.databaseURL)
        let later = UsageScanner(store: fixture.store, device: devices[1], priority: priority)
        let earlier = UsageScanner(store: fixture.store, device: devices[0], priority: priority)
        let first = try await later.scan(source: source)
        #expect(first.issues.isEmpty, "\(first.issues)")
        #expect(first.insertedRequests == 1)
        #expect(try await earlier.scan(source: source).upgradedRequests == 1)
        #expect(try fixture.store.usageRecords().rows.map(\.device) == [devices[0].id])
        // Replaying a lower-priority copy cannot take ownership back.
        try await fixture.store.pool.write { try $0.execute(sql: "UPDATE scan_files SET parser_state_json=NULL") }
        #expect(try await later.scan(source: source).duplicateRequests == 1)
        #expect(try fixture.store.usageRecords().rows.map(\.device) == [devices[0].id])
        #expect(try fixture.store.usageReport(UsageQuery(grouping: .total)).rows.first?.totalTokens == 120)
    }

    @Test func stoppingAndAwaitingOtherScanBeforeRemovalReplaysSharedHistory() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let other = RemoteDevice(name: "Other", connection: .directory(path: "/synthetic", bookmark: nil))
        let priority = DevicePriority(devices: [fixture.device, other])
        let source = Source(data: Data((header + record(1)).utf8), database: fixture.store.databaseURL)
        _ = try await UsageScanner(store: fixture.store, device: fixture.device, priority: priority).scan(source: source)
        let scanner = UsageScanner(store: fixture.store, device: other, priority: priority)
        _ = try await scanner.scan(source: source)
        await source.append(Data(record(2).utf8))
        await source.pauseNextRead()
        let running = Task { try await scanner.scan(source: source) }
        defer { running.cancel() }
        for _ in 0..<1_000 {
            if await source.readPaused { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await source.readPaused)
        running.cancel()
        do {
            _ = try await running.value
            Issue.record("The interrupted scan must finish cancellation before deletion")
        } catch is CancellationError { }
        try fixture.store.removeDeviceData(device: fixture.device.id, deleteUsage: true)
        let resumed = try await scanner.scan(source: source)
        #expect(resumed.insertedRequests == 2)
        let rows = try fixture.store.usageRecords().rows
        #expect(Set(rows.compactMap(\.responseID)) == ["response-1", "response-2"])
        #expect(rows.allSatisfy { $0.device == other.id })
        #expect(try await scanner.scan(source: source).unchangedFiles == 1)
    }

    @Test(arguments: [false, true])
    func accountAttributionUsesCreatorThenSourceLogin(remote: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let device = remote ? fixture.device : RemoteDevice.local(root: fixture.root)
        let creatorHeader = header.replacingOccurrences(of: "\"id\":", with: "\"creator_account_id\":\"creator\",\"id\":")
        let source = Source(data: Data((creatorHeader + record(1)).utf8), database: fixture.store.databaseURL)
        var scanner = UsageScanner(store: fixture.store, device: device, priority: DevicePriority(), accountID: "login")
        _ = try await scanner.scan(source: source)
        #expect(try fixture.store.usageRecords().rows.map(\.accountID) == ["creator"])
        scanner.accountID = "other-login"
        await source.append(Data(record(2).utf8))
        _ = try await scanner.scan(source: source)
        #expect(try fixture.store.usageRecords().rows.allSatisfy { $0.accountID == "creator" })
    }

    @Test func creatorFromAnotherCopyOverridesLoginFallback() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let remote = Source(data: Data((header + record(1)).utf8), database: fixture.store.databaseURL)
        _ = try await UsageScanner(store: fixture.store, device: fixture.device, priority: DevicePriority(), accountID: "remote-login")
            .scan(source: remote)
        let creatorHeader = header.replacingOccurrences(of: "\"id\":", with: "\"creator_account_id\":\"creator\",\"id\":")
        let local = Source(data: Data((creatorHeader + record(1)).utf8), database: fixture.store.databaseURL)
        _ = try await UsageScanner(store: fixture.store, device: .local(root: fixture.root), priority: DevicePriority(), accountID: "local-login")
            .scan(source: local)
        let rows = try fixture.store.usageRecords().rows
        #expect(rows.count == 1)
        #expect(rows.first?.accountID == "creator")
        #expect(rows.first?.device == "local")
    }

    @Test func replayFillsUnknownAccountWithoutDuplicatingUsage() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let source = Source(data: Data((header + record(1)).utf8), database: fixture.store.databaseURL)
        var scanner = UsageScanner(store: fixture.store, device: fixture.device, priority: DevicePriority())
        _ = try await scanner.scan(source: source)
        #expect(try fixture.store.usageRecords().rows.first?.accountID == nil)
        try await fixture.store.pool.write { db in
            try db.execute(sql: "UPDATE scan_files SET parser_state_json = json_set(parser_state_json, '$.version', 9)")
        }
        scanner.accountID = "source-login"
        let replay = try await scanner.scan(source: source)
        #expect(replay.insertedRequests == 0 && replay.upgradedRequests == 1)
        #expect(try fixture.store.usageRecords().rows.map(\.accountID) == ["source-login"])
        scanner.accountID = "changed-login"
        await source.append(Data(record(2).utf8))
        _ = try await scanner.scan(source: source)
        #expect(try fixture.store.usageRecords().rows.allSatisfy { $0.accountID == "source-login" })
    }

    @Test func localAndRemoteCyclesMergeOnlyWithinTheSameAccount() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let reset: Int64 = 1_789_084_800
        let limits = """
        {"timestamp":"2026-09-09T00:00:02Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"secondary":{"used_percent":40,"window_minutes":10080,"resets_at":\(reset)}}}}

        """
        let first = header.replacingOccurrences(of: "\"id\":", with: "\"creator_account_id\":\"a\",\"id\":") + record(1) + limits
        let source = Source(data: Data(first.utf8), database: fixture.store.databaseURL)
        _ = try await UsageScanner(store: fixture.store, device: .local(root: fixture.root), priority: DevicePriority())
            .scan(source: source)
        _ = try await UsageScanner(store: fixture.store, device: fixture.device, priority: DevicePriority())
            .scan(source: source)
        try fixture.store.saveCompletedWeeklyCycles()
        var rows = try fixture.store.weeklyLimitHistory().rows
        #expect(rows.count == 1)
        #expect(rows.first?.accountID == "a" && rows.first?.totalTokens == 120)
        let second = first.replacingOccurrences(of: "\"creator_account_id\":\"a\"", with: "\"creator_account_id\":\"b\"")
            .replacingOccurrences(of: "00000000-0000-0000-0000-000000000001", with: "00000000-0000-0000-0000-000000000002")
            .replacingOccurrences(of: "turn-1", with: "turn-2")
        await source.setOlderLog(Data(second.utf8))
        _ = try await UsageScanner(store: fixture.store, device: fixture.device, priority: DevicePriority()).scan(source: source)
        try fixture.store.saveCompletedWeeklyCycles()
        rows = try fixture.store.weeklyLimitHistory().rows
        #expect(Set(rows.compactMap(\.accountID)) == ["a", "b"])
        #expect(rows.allSatisfy { $0.totalTokens == 120 && $0.requestCount == 1 })
    }

    private struct Fixture {
        let root: URL
        let store: UsageStore
        let device = RemoteDevice(name: "Source", connection: .directory(path: "/synthetic", bookmark: nil))
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        }
        func clean() { try? FileManager.default.removeItem(at: root) }
    }

    private actor Source: DeviceFileSource {
        var data: Data
        var modified: Double = 1
        var transferred = 0
        var duplicate: Data?
        var olderLog: Data?
        var failingOffset: UInt64?
        var readPaused = false
        private var pauseRead = false
        func pauseNextRead() { pauseRead = true }
        func failReads(at offset: UInt64?) { failingOffset = offset }
        let database: URL
        init(data: Data, database: URL) { self.data = data; self.database = database }
        func append(_ bytes: Data) { data.append(bytes); modified += 1 }
        func resetTransferred() { transferred = 0 }
        func setDuplicate(_ bytes: Data) { duplicate = bytes; modified += 1 }
        func setOlderLog(_ bytes: Data) { olderLog = bytes }
        func probe() -> String { "/synthetic" }
        func manifest() -> DeviceSourceManifest {
            var files = [DeviceSourceFile(
                path: "sessions/rollout-2026-09-09T00-00-00-00000000-0000-0000-0000-000000000001.jsonl",
                size: UInt64(data.count), modifiedAt: modified, identity: "synthetic")]
            if let duplicate {
                files.append(DeviceSourceFile(path: "archived_sessions/rollout-2026-09-09T00-00-00-00000000-0000-0000-0000-000000000001.jsonl",
                    size: UInt64(duplicate.count), modifiedAt: modified, identity: "duplicate"))
            }
            if let olderLog {
                files.append(DeviceSourceFile(path: "archived_sessions/rollout-2026-09-08T00-00-00-00000000-0000-0000-0000-000000000002.jsonl",
                    size: UInt64(olderLog.count), modifiedAt: 0, identity: "older"))
            }
            return DeviceSourceManifest(root: "/synthetic", files: files)
        }
        func read(_ file: DeviceSourceFile, offset: UInt64, count: Int) async throws -> Data {
            if pauseRead {
                pauseRead = false
                readPaused = true
                try await Task.sleep(for: .seconds(60))
            }
            // A read-only transport must never be called under the destination writer lock.
            try FileWriteLock(url: database.appendingPathExtension("write.lock")).withLock(nonBlocking: true) {}
            if let failingOffset, offset >= failingOffset { throw DeviceSourceFailure.inaccessible }
            transferred += count
            let bytes = file.identity == "duplicate" ? duplicate! : file.identity == "older" ? olderLog! : data
            return bytes.subdata(in: Int(offset)..<(Int(offset) + count))
        }
    }

    private let header = "{\"timestamp\":\"2026-09-09T00:00:00Z\",\"type\":\"session_meta\",\"payload\":{\"id\":\"00000000-0000-0000-0000-000000000001\"}}\n{\"type\":\"turn_context\",\"payload\":{\"turn_id\":\"turn-1\",\"model\":\"gpt-test\"}}\n"
    private func record(_ number: Int) -> String {
        "{\"timestamp\":\"2026-09-09T00:00:0\(number % 10)Z\",\"type\":\"token_usage_record\",\"payload\":{\"thread_id\":\"00000000-0000-0000-0000-000000000001\",\"turn_id\":\"turn-1\",\"response_id\":\"response-\(number)\",\"usage\":{\"input_tokens\":100,\"output_tokens\":20,\"total_tokens\":120},\"thread_token_usage\":{\"input_tokens\":\(100 * number),\"output_tokens\":\(20 * number),\"total_tokens\":\(120 * number)}}}\n"
    }
}
