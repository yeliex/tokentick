import Darwin
import Foundation
import GRDB
import libzstd
import Testing
@testable import TokenTickCore

struct LocalUsageScannerTests {
    @Test func localCopyTakesOwnershipAndDeviceFiltersSurviveSourceChanges() async throws {
        let local = try Fixture()
        let remote = try Fixture()
        defer { local.clean(); remote.clean() }
        var remoteDevice = RemoteDevice(name: "Remote", connection: .directory(path: "/fixture", bookmark: nil))
        let device = remoteDevice.id
        let scanner = UsageScanner(store: local.store, device: remoteDevice, priority: DevicePriority())
        _ = try local.write(local.header + local.turn + local.record(1))
        _ = try remote.write(remote.header + remote.turn + remote.record(1) + remote.record(2))
        #expect(try await scanner.scan(source: LocalFileSource(root: remote.root)).insertedRequests == 2)
        #expect(try await local.scan().upgradedRequests == 1)
        #expect(try local.total() == 240)
        let records = try local.store.usageRecords().rows
        #expect(records.count == 2)
        #expect(records.allSatisfy { $0.accountID == nil })
        #expect(records.first { $0.responseID == "response-1" }?.device == "local")
        #expect(records.first { $0.responseID == "response-2" }?.device == device)
        let path = try #require(records.first { $0.responseID == "response-1" }?.lastKnownPath)
        #expect(URL(fileURLWithPath: path).resolvingSymlinksInPath().path.hasPrefix(local.root.resolvingSymlinksInPath().path))
        #expect(try local.store.tableCounts()["scan_files"] == 2)
        #expect(try await scanner.scan(source: LocalFileSource(root: remote.root)).unchangedFiles == 1)
        var query = UsageQuery(grouping: .total, timezone: "UTC")
        #expect(try local.store.usageReport(query).rows.first?.totalTokens == 240)
        query.filters.device = .value(device)
        #expect(try local.store.usageReport(query).rows.first?.totalTokens == 120)
        #expect(try local.store.usageRecords(query).rows.count == 1)
        #expect(try local.store.usageFilterOptions().devices.sorted() == [device, "local"].sorted())
        query.filters.device = .value("local")
        #expect(try local.store.usageReport(query).rows.first?.totalTokens == 120)
        remoteDevice.edit(name: "Remote", connection: .directory(path: "/changed", bookmark: nil), enabled: true)
        #expect(try await UsageScanner(store: local.store, device: remoteDevice, priority: DevicePriority())
            .scan(source: LocalFileSource(root: remote.root)).scannedFiles == 1)
        #expect(try local.total() == 240)
    }

    @Test func removingDeviceRetainsOrDeletesFactsAndReplaysRemainingCopies() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        _ = try fixture.write(fixture.header + fixture.turn + fixture.record(1))
        let firstDevice = RemoteDevice(name: "First", connection: .directory(path: "/fixture", bookmark: nil))
        let first = firstDevice.id
        let secondDevice = RemoteDevice(name: "Second", connection: .directory(path: "/fixture", bookmark: nil))
        let second = secondDevice.id
        _ = try await UsageScanner(store: fixture.store, device: firstDevice, priority: DevicePriority()).scan(source: LocalFileSource(root: fixture.root))
        _ = try await UsageScanner(store: fixture.store, device: secondDevice, priority: DevicePriority()).scan(source: LocalFileSource(root: fixture.root))
        try fixture.store.removeDeviceData(device: first, deleteUsage: false)
        #expect(try fixture.total() == 120)
        #expect(try fixture.store.usageRecords().rows.first?.device == first)
        try fixture.store.removeDeviceData(device: first, deleteUsage: true)
        #expect(try fixture.total() == 0)
        #expect(try await UsageScanner(store: fixture.store, device: secondDevice, priority: DevicePriority()).scan(source: LocalFileSource(root: fixture.root)).insertedRequests == 1)
        #expect(try fixture.store.usageRecords().rows.first?.device == second)
        #expect(throws: DeviceConfigurationError.self) {
            try fixture.store.removeDeviceData(device: "local", deleteUsage: true)
        }
    }

    @Test func removingDeviceRollsBackCursorsWhenFactDeletionFails() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        _ = try fixture.write(fixture.header + fixture.turn + fixture.record(1))
        let remoteDevice = RemoteDevice(name: "Remote", connection: .directory(path: "/fixture", bookmark: nil))
        let device = remoteDevice.id
        _ = try await UsageScanner(store: fixture.store, device: remoteDevice, priority: DevicePriority()).scan(source: LocalFileSource(root: fixture.root))
        try await fixture.store.pool.write { db in
            try db.execute(sql: "INSERT INTO app_metadata(key,value) VALUES (?,?)", arguments: ["fast_trace_cursor:" + device + ":0:logs.sqlite", "fixture"])
            try db.execute(sql: "CREATE TRIGGER reject_test_delete BEFORE DELETE ON usage BEGIN SELECT RAISE(ABORT,'injected failure'); END")
        }
        #expect(throws: (any Error).self) { try fixture.store.removeDeviceData(device: device, deleteUsage: true) }
        #expect(try fixture.total() == 120)
        #expect(try fixture.store.tableCounts()["scan_files"] == 1)
        let metadata = try await fixture.store.pool.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM app_metadata WHERE key=?", arguments: ["fast_trace_cursor:" + device + ":0:logs.sqlite"])
        }
        #expect(metadata == "fixture")
        try await fixture.store.pool.write { try $0.execute(sql: "DROP TRIGGER reject_test_delete") }
        try fixture.store.removeDeviceData(device: device, deleteUsage: true)
        #expect(try fixture.total() == 0)
        #expect(try fixture.store.tableCounts()["scan_files"] == 0)
    }

    @Test func emptySourceIsSuccessfulWithoutUsage() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let report = try await fixture.scan()
        #expect(report.discoveredFiles == 0 && report.issueCount == 0)
        #expect(try fixture.store.usageRecords().rows.isEmpty)
    }

    @Test func sourceDatabaseFailuresKeepCollectedUsageAndActionableDiagnostics() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        _ = try fixture.write(fixture.header + fixture.turn + fixture.count(1))
        for name in ["state_5.sqlite", "logs_2.sqlite"] {
            try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let report = try await fixture.scan()
        #expect(report.insertedRequests == 1)
        #expect(try fixture.total() == 120)
        #expect(!report.catalogAvailable)
        for (reason, name) in [("catalog", "state_5.sqlite"), ("fast_evidence", "logs_2.sqlite")] {
            #expect(report.diagnosticCounts[reason] == 1)
            let message = try #require(report.diagnosticSamples[reason]?.message)
            #expect(message.contains(fixture.root.appendingPathComponent(name).path))
            #expect(message.contains("directory=true"))
            #expect(message.contains("SQLite open failed"))
        }
    }

    @Test func codexHomeReadsRuntimeEnvironmentEachTime() {
        let saved = getenv("CODEX_HOME").map { String(cString: $0) }
        defer {
            if let saved { setenv("CODEX_HOME", saved, 1) } else { unsetenv("CODEX_HOME") }
        }
        setenv("CODEX_HOME", "/tmp/tokentick-first", 1)
        #expect(LocalUsageScanner.defaultCodexHome.path == "/tmp/tokentick-first")
        setenv("CODEX_HOME", "/tmp/tokentick-second", 1)
        #expect(LocalUsageScanner.defaultCodexHome.path == "/tmp/tokentick-second")
        unsetenv("CODEX_HOME")
        #expect(LocalUsageScanner.defaultCodexHome == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true))
    }

    @Test func appendingPartialLineAndRestartDoesNotLoseOrDuplicateUsage() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let file = try fixture.write(fixture.header + fixture.turn + fixture.count(1))
        let first = try await fixture.scan()
        #expect(first.insertedRequests == 1)
        let next = fixture.count(2)
        let split = next.index(next.startIndex, offsetBy: next.count / 2)
        try fixture.append(String(next[..<split]), to: file)
        #expect(try await fixture.scan().insertedRequests == 0)
        try fixture.append(String(next[split...]), to: file)
        let reopened = try UsageStore(databaseURL: fixture.database)
        #expect(try await LocalUsageScanner(store: reopened).scan(codexHome: fixture.root).insertedRequests == 1)
        #expect(try fixture.total() == 240)
        #expect(try await fixture.scan().unchangedFiles == 1)
        #expect(try fixture.rows().allSatisfy { ($0["amount"] as Int64?) == nil && ($0["tier"] as String?) == nil })
    }

    @Test func archiveAndCompressionKeepRolloutIdentityAndUsage() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let text = fixture.header + fixture.turn + fixture.count(1)
        let original = try fixture.write(text)
        _ = try await fixture.scan()
        let archived = fixture.root.appendingPathComponent("archived_sessions/" + original.lastPathComponent)
        try FileManager.default.moveItem(at: original, to: archived)
        #expect(try await fixture.scan().unchangedFiles == 1)
        let storedPath = try #require(await fixture.store.pool.read { try String.fetchOne($0, sql: "SELECT current_path FROM scan_files") })
        #expect(URL(fileURLWithPath: storedPath).resolvingSymlinksInPath() == archived.resolvingSymlinksInPath())
        let compressed = archived.appendingPathExtension("zst")
        try compress(Data(text.utf8)).write(to: compressed)
        try FileManager.default.removeItem(at: archived)
        #expect(try await fixture.scan().duplicateRequests == 1)
        #expect(try fixture.total() == 120)
        #expect(try fixture.store.tableCounts()["scan_files"] == 1)
        try FileManager.default.removeItem(at: compressed)
        _ = try await fixture.scan()
        #expect(try fixture.total() == 120)
    }

    @Test func unchangedFilesDoNotRewriteScanCheckpoints() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        _ = try fixture.write(fixture.header + fixture.turn + fixture.count(1))
        _ = try await fixture.scan()
        try await fixture.store.pool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_checkpoint_update BEFORE UPDATE ON scan_files
                BEGIN SELECT RAISE(ABORT, 'Unchanged checkpoints must not be written'); END
                """)
        }
        let report = try await fixture.scan()
        #expect(report.unchangedFiles == 1 && report.scannedBytes == 0)
        #expect(report.issueCount == 0)
        #expect(try fixture.total() == 120)
    }

    @Test func legacyParserStateReplaysOnceToBackfillNewMetadata() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let file = try fixture.write(fixture.header + fixture.turn + fixture.count(1))
        _ = try await fixture.scan()
        // A checkpoint version change requires rescanning; deduplicate already committed usage by identity.
        try await fixture.store.pool.write { db in
            try db.execute(sql: "UPDATE scan_files SET parser_state_json = json_set(parser_state_json, '$.version', 6, '$.contextTurnID', 'turn-1')")
        }
        let next = fixture.count(2)
        try fixture.append(next, to: file)
        let reopened = try UsageStore(databaseURL: fixture.database)
        let report = try await LocalUsageScanner(store: reopened).scan(codexHome: fixture.root)
        #expect(report.insertedRequests == 1 && report.duplicateRequests == 1)
        #expect(report.scannedBytes == UInt64((fixture.header + fixture.turn + fixture.count(1) + next).utf8.count))
        #expect(try fixture.total() == 240)
        #expect(try await fixture.scan().unchangedFiles == 1)
    }

    @Test func revertedRolloutRetainsOldRequestsAndDeduplicatesCopiedPrefix() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        _ = try fixture.write(fixture.header + fixture.turn + fixture.count(1))
        _ = try await fixture.scan()
        let revertedName = fixture.fileName.replacingOccurrences(of: ".jsonl", with: "_00000000-0000-0000-0000-000000000003.jsonl")
        _ = try fixture.write(fixture.header + fixture.turn + fixture.count(1) + fixture.count(2), name: revertedName)
        _ = try await fixture.scan()
        #expect(try fixture.total() == 240)
        #expect(try fixture.store.tableCounts()["scan_files"] == 2)
        #expect(try fixture.store.tableCounts()["threads"] == 1)
    }

    @Test func forkWithBoundaryAtEndHasNoOwnUsage() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let header = "{\"timestamp\":\"2026-09-09T00:00:00Z\",\"ordinal\":0,\"type\":\"session_meta\",\"payload\":{\"id\":\"\(fixture.thread)\",\"forked_from_id\":\"parent\",\"subagent_history_start_ordinal\":100,\"history_mode\":\"paginated\"}}\n"
        _ = try fixture.write(header + fixture.turn + fixture.count(1))
        let report = try await fixture.scan()
        #expect(report.issueCount == 0)
        #expect(report.inheritedEvents == 1)
        #expect(try fixture.total() == 0)
    }

    @Test func newRequestRecordUpgradesLegacyAcrossRestartAndReplay() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let file = try fixture.write(fixture.header + fixture.turn + fixture.count(1))
        _ = try await fixture.scan()
        try fixture.append(fixture.record(1), to: file)
        #expect(try await fixture.scan().upgradedRequests == 1)
        #expect(try fixture.total() == 120)
        let rows = try fixture.rows()
        #expect(rows.count == 1)
        #expect(try await fixture.store.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(DISTINCT turn_key) FROM usage") } == 1)
        #expect(try await fixture.store.pool.read { try String.fetchOne($0, sql: "SELECT response_id FROM usage") } == "response-1")
        // An in-place rewrite triggers a rescan; previous aliases must still resolve to the same request.
        try Data((fixture.header + fixture.turn + fixture.count(1) + fixture.record(1)).utf8).write(to: file, options: .atomic)
        _ = try await fixture.scan()
        #expect(try fixture.rows().count == 1)
        #expect(try fixture.total() == 120)
    }

    @Test func modernThenLegacyAndRepeatedHeartbeatsCountOnce() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        _ = try fixture.write(fixture.header + fixture.turn + fixture.record(1) + fixture.count(1) + fixture.count(1))
        _ = try await fixture.scan()
        #expect(try fixture.rows().count == 1)
        #expect(try fixture.total() == 120)
    }

    @Test func truncationAndReplacementPreserveRealHistory() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let file = try fixture.write(fixture.header + fixture.turn + fixture.count(1) + fixture.count(2))
        _ = try await fixture.scan()
        try Data((fixture.header + fixture.turn + fixture.count(1)).utf8).write(to: file)
        _ = try await fixture.scan()
        #expect(try fixture.total() == 240)
        try Data((fixture.header + fixture.turn + fixture.count(3)).utf8).write(to: file, options: .atomic)
        _ = try await fixture.scan()
        #expect(try fixture.total() == 360)
    }

    @Test func malformedLineDoesNotAdvanceCursorAndCanBeRepaired() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let file = try fixture.write(fixture.header + fixture.turn + fixture.count(1) + "{broken}\n" + fixture.count(2))
        #expect(try await fixture.scan().issueCount == 1)
        #expect(try fixture.total() == 120)
        #expect(try await fixture.scan().issueCount == 1)
        try Data((fixture.header + fixture.turn + fixture.count(1) + fixture.count(2)).utf8).write(to: file, options: .atomic)
        #expect(try await fixture.scan().issueCount == 0)
        #expect(try fixture.total() == 240)
    }

    @Test func conflictingCopiesAreNotSilentlySelected() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        _ = try fixture.write(fixture.header + fixture.turn + fixture.count(1))
        try compress(Data((fixture.header + fixture.turn + fixture.count(2)).utf8))
            .write(to: fixture.root.appendingPathComponent("archived_sessions/" + fixture.fileName + ".zst"))
        #expect(try await fixture.scan().issueCount == 1)
        #expect(try fixture.total() == 0)
    }

    @Test func plainSiblingIsAuthoritativeWithoutDecodingTheCompressedSibling() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let file = try fixture.write(fixture.header + fixture.turn + fixture.count(1))
        let sibling = file.appendingPathExtension("zst")
        // Prefer the plain file as Codex does even when its compressed sibling cannot be decoded.
        try Data("not a zstandard stream".utf8).write(to: sibling)
        let first = try await fixture.scan()
        #expect(first.discoveredFiles == 2 && first.scannedFiles == 1 && first.insertedRequests == 1)
        #expect(first.issueCount == 0)
        try fixture.append(fixture.count(2), to: file)
        #expect(try await fixture.scan().insertedRequests == 1)
        #expect(try fixture.total() == 240)
        try FileManager.default.removeItem(at: file)
        #expect(try await fixture.scan().issueCount == 1)
        #expect(try fixture.total() == 240)
    }

    @Test func immutableCompressedFileIsSkippedUntilMaterializedForAppend() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let text = fixture.header + fixture.turn + fixture.count(1)
        let plain = fixture.root.appendingPathComponent("sessions/" + fixture.fileName)
        let compressed = plain.appendingPathExtension("zst")
        try compress(Data(text.utf8)).write(to: compressed)
        #expect(try await fixture.scan().insertedRequests == 1)
        let unchanged = try await fixture.scan()
        #expect(unchanged.unchangedFiles == 1 && unchanged.scannedBytes == 0 && unchanged.scannedFiles == 0)
        try Data((text + fixture.count(2)).utf8).write(to: plain)
        // A materialized plain file may include new usage; it need not match its older compressed sibling.
        let materialized = try await fixture.scan()
        #expect(materialized.issueCount == 0 && materialized.insertedRequests == 1)
        #expect(try fixture.total() == 240)
        try FileManager.default.removeItem(at: compressed)
        #expect(try await fixture.scan().unchangedFiles == 1)
    }

    @Test(arguments: [17, 64 * 1_024])
    func largeCompressedLinesAreStreamedAndTruncationDetected(readSize: Int) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let text = String(repeating: "a", count: 512 * 1_024) + "\nlast\n"
        let data = try compress(Data(text.utf8))
        try data.write(to: root)
        let reader = try RolloutLineReader(handle: LocalRolloutFile(url: root), compressed: true, readSize: readSize)
        #expect(try await reader.nextLine()?.count == 512 * 1_024)
        #expect(try await reader.nextLine() == Data("last".utf8))
        #expect(try await reader.nextLine() == nil)
        try data.dropLast(2).write(to: root)
        let broken = try RolloutLineReader(handle: LocalRolloutFile(url: root), compressed: true, readSize: readSize)
        await #expect(throws: RolloutLineReader.ReadError.self) {
            while try await broken.nextLine() != nil {}
        }
    }

    @Test func concurrentScansSerializeWriters() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        _ = try fixture.write(fixture.header + fixture.turn + fixture.count(1))
        let store2 = try UsageStore(databaseURL: fixture.database)
        let home = fixture.root
        let store1 = fixture.store
        try await withThrowingTaskGroup(of: ScanReport.self) { group in
            group.addTask { try await LocalUsageScanner(store: store1).scan(codexHome: home) }
            group.addTask { try await LocalUsageScanner(store: store2).scan(codexHome: home) }
            var inserted = 0
            for try await report in group { inserted += report.insertedRequests }
            #expect(inserted == 1)
        }
        #expect(try fixture.total() == 120)
    }

    @Test func requestConflictRollsBackUsageAndCursorTogether() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let file = try fixture.write(fixture.header + fixture.turn + fixture.record(1))
        _ = try await fixture.scan()
        let oldLine = try await fixture.store.pool.read { try Int.fetchOne($0, sql: "SELECT scanned_line FROM scan_files") }
        let beforeTurn = try fixture.turnRows()
        let different = fixture.record(1).replacingOccurrences(of: #""input_tokens":100"#, with: #""input_tokens":101"#)
        try fixture.append(fixture.count(2) + different, to: file)
        await #expect(throws: (any Error).self) { try await fixture.scan() }
        #expect(try fixture.total() == 120)
        let line = try await fixture.store.pool.read { try Int.fetchOne($0, sql: "SELECT scanned_line FROM scan_files") }
        #expect(line == oldLine)
        #expect(try fixture.turnRows() == beforeTurn)
    }

    @Test func failedLaterBatchKeepsCommittedPrefixAndResumes() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let padding = String(repeating: "{\"type\":\"ignored\"}\n", count: 600)
        let file = try fixture.write(fixture.header + fixture.turn + fixture.count(1) + padding + "{broken}\n")
        #expect(try await fixture.scan().issueCount == 1)
        #expect(try fixture.total() == 120)
        try Data((fixture.header + fixture.turn + fixture.count(1) + padding + fixture.count(2)).utf8).write(to: file, options: .atomic)
        #expect(try await fixture.scan().issueCount == 0)
        #expect(try fixture.total() == 240)
    }

    @Test func zeroBreakdownContextPlaceholderDoesNotBecomeRequest() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let placeholder = "{\"timestamp\":\"2026-09-09T00:00:02Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":0,\"output_tokens\":0,\"total_tokens\":200000},\"last_token_usage\":{\"input_tokens\":0,\"output_tokens\":0,\"total_tokens\":199880}}}}\n"
        _ = try fixture.write(fixture.header + fixture.turn + fixture.count(1) + placeholder)
        _ = try await fixture.scan()
        #expect(try fixture.total() == 120)
    }

    @Test func inheritedParentSessionMetadataCannotReplaceChildIdentity() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let header = "{\"timestamp\":\"2026-09-09T00:00:00Z\",\"ordinal\":0,\"type\":\"session_meta\",\"payload\":{\"id\":\"\(fixture.thread)\",\"forked_from_id\":\"parent\",\"subagent_history_start_ordinal\":12,\"history_mode\":\"paginated\"}}\n"
        let parent = "{\"timestamp\":\"2026-09-08T00:00:00Z\",\"ordinal\":1,\"type\":\"session_meta\",\"payload\":{\"id\":\"parent\"}}\n"
        _ = try fixture.write(header + parent + fixture.turn + fixture.count(1) + fixture.count(2))
        let report = try await fixture.scan()
        #expect(report.issueCount == 0)
        #expect(report.inheritedEvents == 1)
        #expect(try fixture.total() == 120)
    }

    @Test func oversizedToolBodyIsSkippedWithoutLosingFollowingUsage() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let body = "{\"timestamp\":\"2026-09-09T00:00:00Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"function_call_output\",\"output\":\""
            + String(repeating: "x", count: 18 * 1_024 * 1_024) + "\"}}\n"
        _ = try fixture.write(fixture.header + fixture.turn + body + fixture.count(1))
        let report = try await fixture.scan()
        #expect(report.issueCount == 0)
        #expect(report.insertedRequests == 1)
        let line: Int? = try fixture.rows().first?["source_line"]
        #expect(line == 4)
    }

    @Test func latestThreadAndProjectNamesReplaceCachedMapping() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        _ = try fixture.write(fixture.header + fixture.turn + fixture.count(1))
        let source = try DatabaseQueue(path: fixture.root.appendingPathComponent("state_5.sqlite").path)
        try await source.write { db in
            try db.execute(sql: "CREATE TABLE threads(id TEXT PRIMARY KEY, title TEXT, name TEXT, project_id TEXT); CREATE TABLE projects(id TEXT PRIMARY KEY, name TEXT)")
            try db.execute(sql: "INSERT INTO projects VALUES ('p', '旧项目'); INSERT INTO threads VALUES (?, '原标题', NULL, 'p')", arguments: [fixture.thread])
        }
        #expect(try await fixture.scan().catalogAvailable)
        #expect(try fixture.store.usageSummaries(grouping: .project).first?.group == "旧项目")
        try await source.write { db in
            try db.execute(sql: "UPDATE projects SET name = '新项目'; UPDATE threads SET name = '新标题'")
        }
        #expect(try await fixture.scan().refreshedThreads == 1)
        #expect(try fixture.store.usageSummaries(grouping: .project).first?.group == "新项目")
        let title = try await fixture.store.pool.read { try String.fetchOne($0, sql: "SELECT title FROM threads") }
        #expect(title == "新标题")
        #expect(try fixture.total() == 120)
    }

    @Test func jsonQueryKeepsUnknownValuesAsNull() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        _ = try fixture.write(fixture.header + fixture.turn + fixture.count(1))
        _ = try await fixture.scan()
        let summaries = try fixture.store.usageSummaries(grouping: .project)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(summaries)) as? [[String: Any]]
        #expect(json?.first?["group"] is NSNull)
        #expect(json?.first?["knownAmountNanoUSD"] is NSNull)
        #expect(summaries.first?.unpricedTokens == 120)
    }

    @Test func alreadyKnownResponseRemovesLegacyCopyInAnotherRevert() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        _ = try fixture.write(fixture.header + fixture.turn + fixture.record(1))
        _ = try await fixture.scan()
        let name = fixture.fileName.replacingOccurrences(of: ".jsonl", with: "_00000000-0000-0000-0000-000000000004.jsonl")
        let file = try fixture.write(fixture.header + fixture.turn + fixture.count(1) + fixture.record(1), name: name)
        _ = try await fixture.scan()
        #expect(try fixture.total() == 120)
        try Data((fixture.header + fixture.turn + fixture.count(1) + fixture.record(1)).utf8).write(to: file, options: .atomic)
        #expect(try await fixture.scan().insertedRequests == 0)
        #expect(try fixture.rows().count == 1)
    }

    @Test func failedCheckpointCommitKeepsEarlierBatchAndRestartResumes() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let padding = String(repeating: "{\"type\":\"ignored\"}\n", count: 509)
        _ = try fixture.write(fixture.header + fixture.turn + fixture.count(1) + padding + fixture.count(2))
        try await fixture.store.pool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_later_checkpoint BEFORE UPDATE ON scan_files
                WHEN NEW.scanned_line > 512 BEGIN SELECT RAISE(ABORT, 'Injected commit failure'); END
                """)
        }
        await #expect(throws: (any Error).self) { try await fixture.scan() }
        #expect(try fixture.total() == 120)
        #expect(try await fixture.store.pool.read { try Int.fetchOne($0, sql: "SELECT scanned_line FROM scan_files") } == 512)
        try await fixture.store.pool.write { try $0.execute(sql: "DROP TRIGGER reject_later_checkpoint") }
        let reopened = try UsageStore(databaseURL: fixture.database)
        #expect(try await LocalUsageScanner(store: reopened).scan(codexHome: fixture.root).insertedRequests == 1)
        #expect(try fixture.total() == 240)
        #expect(try await fixture.scan().unchangedFiles == 1)
    }

    @Test func cancellationAfterCommittedFileKeepsCheckpointForRestart() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        _ = try fixture.write(fixture.header + fixture.turn + fixture.count(1))
        let store = fixture.store
        let root = fixture.root
        let task = Task {
            try await LocalUsageScanner(store: store).scan(codexHome: root) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {}
        #expect(try fixture.total() == 120)
        let reopened = try UsageStore(databaseURL: fixture.database)
        #expect(try await LocalUsageScanner(store: reopened).scan(codexHome: root).unchangedFiles == 1)
        #expect(try fixture.total() == 120)
    }

    @Test func pricedUsageAndClearedCatalogSurviveRepeatedScans() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let prices = #"{"openai":{"models":{"gpt-test":{"id":"gpt-test","cost":{"input":1.25,"output":2.5,"cache_read":0.125,"cache_write":1.25}}}}}"#
        _ = try fixture.store.savePrices(ModelsDevPrices.decode(Data(prices.utf8), date: "2026-09-09"), date: "2026-09-09")
        _ = try fixture.write(fixture.header + fixture.turn + fixture.record(1) + "{\"type\":\"future_event\",\"payload\":{\"unknown\":true}}\n")
        let source = try DatabaseQueue(path: fixture.root.appendingPathComponent("state_5.sqlite").path)
        try await source.write { db in
            try db.execute(sql: "CREATE TABLE threads(id TEXT PRIMARY KEY, title TEXT, project_id TEXT); CREATE TABLE projects(id TEXT PRIMARY KEY, name TEXT)")
            try db.execute(sql: "INSERT INTO projects VALUES ('p', 'Project'); INSERT INTO threads VALUES (?, 'Title', 'p')", arguments: [fixture.thread])
        }
        _ = try await fixture.scan()
        _ = try fixture.store.repriceUsage()
        let before = try fixture.rows()
        #expect((before.first?["amount"] as Int64?) == 107_500)
        #expect((before.first?["account_id"] as String?) == nil)
        try await source.write { try $0.execute(sql: "UPDATE threads SET title=NULL, project_id=NULL") }
        #expect(try await fixture.scan().refreshedThreads == 1)
        #expect(try await fixture.store.pool.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT title,project_name FROM threads")
            return (row?["title"] as String?) == nil && (row?["project_name"] as String?) == nil
        })
        #expect(try fixture.rows() == before)
        #expect(try await fixture.scan().unchangedFiles == 1)
    }

    private func compress(_ data: Data) throws -> Data {
        var output = Data(count: ZSTD_compressBound(data.count))
        let count = output.withUnsafeMutableBytes { target in
            data.withUnsafeBytes { source in
                ZSTD_compress(target.baseAddress, target.count, source.baseAddress, source.count, 3)
            }
        }
        #expect(ZSTD_isError(count) == 0)
        output.count = count
        return output
    }

    private struct Fixture {
        let root: URL
        let database: URL
        let store: UsageStore
        let thread = "00000000-0000-0000-0000-000000000001"
        var fileName: String { "rollout-2026-09-09T00-00-00-\(thread).jsonl" }
        var header: String { "{\"timestamp\":\"2026-09-09T00:00:00Z\",\"type\":\"session_meta\",\"payload\":{\"id\":\"\(thread)\"}}\n" }
        var turn: String { "{\"type\":\"turn_context\",\"payload\":{\"turn_id\":\"turn-1\",\"model\":\"gpt-test\"}}\n" }
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            database = root.appendingPathComponent("usage.sqlite")
            for directory in ["sessions", "archived_sessions"] {
                try FileManager.default.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
            }
            store = try UsageStore(databaseURL: database)
        }
        func counters(_ n: Int) -> String {
            "{\"input_tokens\":\(100*n),\"cached_input_tokens\":\(60*n),\"cache_write_input_tokens\":0,\"output_tokens\":\(20*n),\"reasoning_output_tokens\":\(12*n),\"total_tokens\":\(120*n)}"
        }
        func count(_ n: Int) -> String {
            "{\"timestamp\":\"2026-09-09T00:00:0\(n)Z\",\"ordinal\":\(n+10),\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":\(counters(n)),\"last_token_usage\":\(counters(1))}}}\n"
        }
        func record(_ n: Int) -> String {
            "{\"timestamp\":\"2026-09-09T00:00:0\(n)Z\",\"type\":\"token_usage_record\",\"payload\":{\"thread_id\":\"\(thread)\",\"turn_id\":\"turn-1\",\"response_id\":\"response-\(n)\",\"usage\":\(counters(1)),\"thread_token_usage\":\(counters(n))}}\n"
        }
        func write(_ text: String, name: String? = nil) throws -> URL {
            let url = root.appendingPathComponent("sessions/" + (name ?? fileName))
            try Data(text.utf8).write(to: url)
            return url
        }
        func append(_ text: String, to url: URL) throws {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
        }
        func turnRows() throws -> [Row] { try store.pool.read { try Row.fetchAll($0, sql: "SELECT DISTINCT turn_key,thread_id,turn_started_at FROM usage") } }
        func scan() async throws -> ScanReport { try await LocalUsageScanner(store: store).scan(codexHome: root) }
        func total() throws -> Int64 {
            try store.pool.read { try Int64.fetchOne($0, sql: "SELECT COALESCE(SUM(total_tokens), 0) FROM usage") ?? 0 }
        }
        func rows() throws -> [Row] { try store.pool.read { try Row.fetchAll($0, sql: "SELECT * FROM usage ORDER BY id") } }
        func clean() { try? FileManager.default.removeItem(at: root) }
    }
}
