import Darwin
import Foundation
import GRDB
import libzstd
import Testing
@testable import TokenTickCore

struct LocalUsageScannerTests {
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

    @Test func appendingPartialLineAndRestartDoesNotLoseOrDuplicateUsage() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let file = try fixture.write(fixture.header + fixture.turn + fixture.count(1))
        let first = try fixture.scan()
        #expect(first.insertedRequests == 1)
        let next = fixture.count(2)
        let split = next.index(next.startIndex, offsetBy: next.count / 2)
        try fixture.append(String(next[..<split]), to: file)
        #expect(try fixture.scan().insertedRequests == 0)
        try fixture.append(String(next[split...]), to: file)
        let reopened = try UsageStore(databaseURL: fixture.database)
        #expect(try LocalUsageScanner(store: reopened).scan(codexHome: fixture.root).insertedRequests == 1)
        #expect(try fixture.total() == 240)
        #expect(try fixture.scan().unchangedFiles == 1)
        #expect(try fixture.rows().allSatisfy { ($0["amount"] as Int64?) == nil && ($0["tier"] as String?) == nil })
    }

    @Test func archiveAndCompressionKeepRolloutIdentityAndUsage() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let text = fixture.header + fixture.turn + fixture.count(1)
        let original = try fixture.write(text)
        _ = try fixture.scan()
        let archived = fixture.root.appendingPathComponent("archived_sessions/" + original.lastPathComponent)
        try FileManager.default.moveItem(at: original, to: archived)
        #expect(try fixture.scan().unchangedFiles == 1)
        let compressed = archived.appendingPathExtension("zst")
        try compress(Data(text.utf8)).write(to: compressed)
        try FileManager.default.removeItem(at: archived)
        #expect(try fixture.scan().duplicateRequests == 1)
        #expect(try fixture.total() == 120)
        #expect(try fixture.store.tableCounts()["scan_files"] == 1)
        try FileManager.default.removeItem(at: compressed)
        _ = try fixture.scan()
        #expect(try fixture.total() == 120)
    }

    @Test func revertedRolloutRetainsOldRequestsAndDeduplicatesCopiedPrefix() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        _ = try fixture.write(fixture.header + fixture.turn + fixture.count(1))
        _ = try fixture.scan()
        let revertedName = fixture.fileName.replacingOccurrences(of: ".jsonl", with: "_00000000-0000-0000-0000-000000000003.jsonl")
        _ = try fixture.write(fixture.header + fixture.turn + fixture.count(1) + fixture.count(2), name: revertedName)
        _ = try fixture.scan()
        #expect(try fixture.total() == 240)
        #expect(try fixture.store.tableCounts()["scan_files"] == 2)
        #expect(try fixture.store.tableCounts()["threads"] == 1)
    }

    @Test func forkWithBoundaryAtEndHasNoOwnUsage() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let header = "{\"timestamp\":\"2026-09-09T00:00:00Z\",\"ordinal\":0,\"type\":\"session_meta\",\"payload\":{\"id\":\"\(fixture.thread)\",\"forked_from_id\":\"parent\",\"subagent_history_start_ordinal\":100,\"history_mode\":\"paginated\"}}\n"
        _ = try fixture.write(header + fixture.turn + fixture.count(1))
        let report = try fixture.scan()
        #expect(report.issueCount == 0)
        #expect(report.inheritedEvents == 1)
        #expect(try fixture.total() == 0)
    }

    @Test func newRequestRecordUpgradesLegacyAcrossRestartAndReplay() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let file = try fixture.write(fixture.header + fixture.turn + fixture.count(1))
        _ = try fixture.scan()
        try fixture.append(fixture.record(1), to: file)
        #expect(try fixture.scan().upgradedRequests == 1)
        #expect(try fixture.total() == 120)
        let rows = try fixture.rows()
        #expect(rows.count == 1)
        #expect(try fixture.store.tableCounts()["turn_usage"] == 1)
        #expect(try fixture.store.pool.read { try String.fetchOne($0, sql: "SELECT response_id FROM usage") } == "response-1")
        // 原地重写触发从头重扫，旧别名也必须命中同一请求。
        try Data((fixture.header + fixture.turn + fixture.count(1) + fixture.record(1)).utf8).write(to: file, options: .atomic)
        _ = try fixture.scan()
        #expect(try fixture.rows().count == 1)
        #expect(try fixture.total() == 120)
    }

    @Test func modernThenLegacyAndRepeatedHeartbeatsCountOnce() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        _ = try fixture.write(fixture.header + fixture.turn + fixture.record(1) + fixture.count(1) + fixture.count(1))
        _ = try fixture.scan()
        #expect(try fixture.rows().count == 1)
        #expect(try fixture.total() == 120)
    }

    @Test func truncationAndReplacementPreserveRealHistory() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let file = try fixture.write(fixture.header + fixture.turn + fixture.count(1) + fixture.count(2))
        _ = try fixture.scan()
        try Data((fixture.header + fixture.turn + fixture.count(1)).utf8).write(to: file)
        _ = try fixture.scan()
        #expect(try fixture.total() == 240)
        try Data((fixture.header + fixture.turn + fixture.count(3)).utf8).write(to: file, options: .atomic)
        _ = try fixture.scan()
        #expect(try fixture.total() == 360)
    }

    @Test func malformedLineDoesNotAdvanceCursorAndCanBeRepaired() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let file = try fixture.write(fixture.header + fixture.turn + fixture.count(1) + "{broken}\n" + fixture.count(2))
        #expect(try fixture.scan().issueCount == 1)
        #expect(try fixture.total() == 120)
        #expect(try fixture.scan().issueCount == 1)
        try Data((fixture.header + fixture.turn + fixture.count(1) + fixture.count(2)).utf8).write(to: file, options: .atomic)
        #expect(try fixture.scan().issueCount == 0)
        #expect(try fixture.total() == 240)
    }

    @Test func conflictingCopiesAreNotSilentlySelected() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        _ = try fixture.write(fixture.header + fixture.turn + fixture.count(1))
        try compress(Data((fixture.header + fixture.turn + fixture.count(2)).utf8))
            .write(to: fixture.root.appendingPathComponent("archived_sessions/" + fixture.fileName + ".zst"))
        #expect(try fixture.scan().issueCount == 1)
        #expect(try fixture.total() == 0)
    }

    @Test func plainSiblingIsAuthoritativeWithoutDecodingTheCompressedSibling() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let file = try fixture.write(fixture.header + fixture.turn + fixture.count(1))
        let sibling = file.appendingPathExtension("zst")
        // 即使旧压缩兄弟不可解码，只要普通文件存在，读取路径也应与 Codex 一致。
        try Data("not a zstandard stream".utf8).write(to: sibling)
        let first = try fixture.scan()
        #expect(first.discoveredFiles == 2 && first.scannedFiles == 1 && first.insertedRequests == 1)
        #expect(first.issueCount == 0)
        try fixture.append(fixture.count(2), to: file)
        #expect(try fixture.scan().insertedRequests == 1)
        #expect(try fixture.total() == 240)
        try FileManager.default.removeItem(at: file)
        #expect(try fixture.scan().issueCount == 1)
        #expect(try fixture.total() == 240)
    }

    @Test func immutableCompressedFileIsSkippedUntilMaterializedForAppend() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let text = fixture.header + fixture.turn + fixture.count(1)
        let plain = fixture.root.appendingPathComponent("sessions/" + fixture.fileName)
        let compressed = plain.appendingPathExtension("zst")
        try compress(Data(text.utf8)).write(to: compressed)
        #expect(try fixture.scan().insertedRequests == 1)
        let unchanged = try fixture.scan()
        #expect(unchanged.unchangedFiles == 1 && unchanged.scannedBytes == 0 && unchanged.scannedFiles == 0)
        try Data((text + fixture.count(2)).utf8).write(to: plain)
        // 解压物化后的普通文件可以已经包含新用量，不能要求它与旧压缩兄弟全文相同。
        let materialized = try fixture.scan()
        #expect(materialized.issueCount == 0 && materialized.insertedRequests == 1)
        #expect(try fixture.total() == 240)
        try FileManager.default.removeItem(at: compressed)
        #expect(try fixture.scan().unchangedFiles == 1)
    }

    @Test func largeCompressedLinesAreStreamedAndTruncationDetected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let text = String(repeating: "a", count: 512 * 1_024) + "\nlast\n"
        let data = try compress(Data(text.utf8))
        try data.write(to: root)
        let reader = try RolloutLineReader(url: root, compressed: true)
        #expect(try reader.nextLine()?.count == 512 * 1_024)
        #expect(try reader.nextLine() == Data("last".utf8))
        #expect(try reader.nextLine() == nil)
        try data.dropLast(2).write(to: root)
        let broken = try RolloutLineReader(url: root, compressed: true)
        #expect(throws: RolloutLineReader.ReadError.self) {
            while try broken.nextLine() != nil {}
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
            group.addTask { try LocalUsageScanner(store: store1).scan(codexHome: home) }
            group.addTask { try LocalUsageScanner(store: store2).scan(codexHome: home) }
            var inserted = 0
            for try await report in group { inserted += report.insertedRequests }
            #expect(inserted == 1)
        }
        #expect(try fixture.total() == 120)
    }

    @Test func requestConflictRollsBackUsageAndCursorTogether() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let file = try fixture.write(fixture.header + fixture.turn + fixture.record(1))
        _ = try fixture.scan()
        let oldLine = try fixture.store.pool.read { try Int.fetchOne($0, sql: "SELECT scanned_line FROM scan_files") }
        let beforeTurn = try fixture.store.pool.read { try Row.fetchAll($0, sql: "SELECT * FROM turn_usage") }
        let different = fixture.record(1).replacingOccurrences(of: #""input_tokens":100"#, with: #""input_tokens":101"#)
        try fixture.append(fixture.count(2) + different, to: file)
        #expect(throws: (any Error).self) { try fixture.scan() }
        #expect(try fixture.total() == 120)
        let line = try fixture.store.pool.read { try Int.fetchOne($0, sql: "SELECT scanned_line FROM scan_files") }
        #expect(line == oldLine)
        #expect(try fixture.store.pool.read { try Row.fetchAll($0, sql: "SELECT * FROM turn_usage") } == beforeTurn)
    }

    @Test func failedLaterBatchKeepsCommittedPrefixAndResumes() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let padding = String(repeating: "{\"type\":\"ignored\"}\n", count: 600)
        let file = try fixture.write(fixture.header + fixture.turn + fixture.count(1) + padding + "{broken}\n")
        #expect(try fixture.scan().issueCount == 1)
        #expect(try fixture.total() == 120)
        try Data((fixture.header + fixture.turn + fixture.count(1) + padding + fixture.count(2)).utf8).write(to: file, options: .atomic)
        #expect(try fixture.scan().issueCount == 0)
        #expect(try fixture.total() == 240)
    }

    @Test func zeroBreakdownContextPlaceholderDoesNotBecomeRequest() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let placeholder = "{\"timestamp\":\"2026-09-09T00:00:02Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":0,\"output_tokens\":0,\"total_tokens\":200000},\"last_token_usage\":{\"input_tokens\":0,\"output_tokens\":0,\"total_tokens\":199880}}}}\n"
        _ = try fixture.write(fixture.header + fixture.turn + fixture.count(1) + placeholder)
        _ = try fixture.scan()
        #expect(try fixture.total() == 120)
    }

    @Test func inheritedParentSessionMetadataCannotReplaceChildIdentity() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let header = "{\"timestamp\":\"2026-09-09T00:00:00Z\",\"ordinal\":0,\"type\":\"session_meta\",\"payload\":{\"id\":\"\(fixture.thread)\",\"forked_from_id\":\"parent\",\"subagent_history_start_ordinal\":12,\"history_mode\":\"paginated\"}}\n"
        let parent = "{\"timestamp\":\"2026-09-08T00:00:00Z\",\"ordinal\":1,\"type\":\"session_meta\",\"payload\":{\"id\":\"parent\"}}\n"
        _ = try fixture.write(header + parent + fixture.turn + fixture.count(1) + fixture.count(2))
        let report = try fixture.scan()
        #expect(report.issueCount == 0)
        #expect(report.inheritedEvents == 1)
        #expect(try fixture.total() == 120)
    }

    @Test func oversizedToolBodyIsSkippedWithoutLosingFollowingUsage() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let body = "{\"timestamp\":\"2026-09-09T00:00:00Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"function_call_output\",\"output\":\""
            + String(repeating: "x", count: 18 * 1_024 * 1_024) + "\"}}\n"
        _ = try fixture.write(fixture.header + fixture.turn + body + fixture.count(1))
        let report = try fixture.scan()
        #expect(report.issueCount == 0)
        #expect(report.insertedRequests == 1)
        let line: Int? = try fixture.rows().first?["source_line"]
        #expect(line == 4)
    }

    @Test func latestThreadAndProjectNamesReplaceCachedMapping() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        _ = try fixture.write(fixture.header + fixture.turn + fixture.count(1))
        let source = try DatabaseQueue(path: fixture.root.appendingPathComponent("state_5.sqlite").path)
        try source.write { db in
            try db.execute(sql: "CREATE TABLE threads(id TEXT PRIMARY KEY, title TEXT, name TEXT, project_id TEXT); CREATE TABLE projects(id TEXT PRIMARY KEY, name TEXT)")
            try db.execute(sql: "INSERT INTO projects VALUES ('p', '旧项目'); INSERT INTO threads VALUES (?, '原标题', NULL, 'p')", arguments: [fixture.thread])
        }
        #expect(try fixture.scan().catalogAvailable)
        #expect(try fixture.store.usageSummaries(grouping: .project).first?.group == "旧项目")
        try source.write { db in
            try db.execute(sql: "UPDATE projects SET name = '新项目'; UPDATE threads SET name = '新标题'")
        }
        #expect(try fixture.scan().refreshedThreads == 1)
        #expect(try fixture.store.usageSummaries(grouping: .project).first?.group == "新项目")
        let title = try fixture.store.pool.read { try String.fetchOne($0, sql: "SELECT title FROM threads") }
        #expect(title == "新标题")
        #expect(try fixture.total() == 120)
    }

    @Test func jsonQueryKeepsUnknownValuesAsNull() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        _ = try fixture.write(fixture.header + fixture.turn + fixture.count(1))
        _ = try fixture.scan()
        let summaries = try fixture.store.usageSummaries(grouping: .project)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(summaries)) as? [[String: Any]]
        #expect(json?.first?["group"] is NSNull)
        #expect(json?.first?["knownAmountNanoUSD"] is NSNull)
        #expect(summaries.first?.unpricedTokens == 120)
    }

    @Test func alreadyKnownResponseRemovesLegacyCopyInAnotherRevert() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        _ = try fixture.write(fixture.header + fixture.turn + fixture.record(1))
        _ = try fixture.scan()
        let name = fixture.fileName.replacingOccurrences(of: ".jsonl", with: "_00000000-0000-0000-0000-000000000004.jsonl")
        let file = try fixture.write(fixture.header + fixture.turn + fixture.count(1) + fixture.record(1), name: name)
        _ = try fixture.scan()
        #expect(try fixture.total() == 120)
        try Data((fixture.header + fixture.turn + fixture.count(1) + fixture.record(1)).utf8).write(to: file, options: .atomic)
        #expect(try fixture.scan().insertedRequests == 0)
        #expect(try fixture.rows().count == 1)
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
        func scan() throws -> ScanReport { try LocalUsageScanner(store: store).scan(codexHome: root) }
        func total() throws -> Int64 {
            try store.pool.read { try Int64.fetchOne($0, sql: "SELECT COALESCE(SUM(total_tokens), 0) FROM usage") ?? 0 }
        }
        func rows() throws -> [Row] { try store.pool.read { try Row.fetchAll($0, sql: "SELECT * FROM usage ORDER BY id") } }
        func clean() { try? FileManager.default.removeItem(at: root) }
    }
}
