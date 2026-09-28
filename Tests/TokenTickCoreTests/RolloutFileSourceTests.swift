import Foundation
import GRDB
import Synchronization
import Testing
@testable import TokenTickCore

struct RolloutFileSourceTests {
    @Test func checkpointReadFailureDoesNotCommitUsageOrCursor() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let thread = "00000000-0000-0000-0000-000000000001"
        let file = sessions.appendingPathComponent("rollout-2026-09-09T00-00-00-\(thread).jsonl")
        let text = """
        {"type":"session_meta","payload":{"id":"\(thread)"}}
        {"timestamp":"2026-09-09T00:00:01Z","type":"token_usage_record","payload":{"thread_id":"\(thread)","turn_id":"turn-1","response_id":"response-1","usage":{"input_tokens":100,"output_tokens":20,"total_tokens":120},"thread_token_usage":{"input_tokens":100,"output_tokens":20,"total_tokens":120}}}

        """
        try Data(text.utf8).write(to: file)
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        let report = try await UsageScanner(store: store, device: .local(root: root), priority: DevicePriority())
            .scan(source: FailingCheckpointSource(root: root))
        #expect(report.issueCount == 1)
        #expect(try store.tableCounts()["usage"] == 0)
        #expect(try store.tableCounts()["scan_files"] == 0)
        let reopened = try UsageStore(databaseURL: store.databaseURL)
        #expect(try await LocalUsageScanner(store: reopened).scan(codexHome: root).insertedRequests == 1)
        #expect(try await LocalUsageScanner(store: reopened).scan(codexHome: root).unchangedFiles == 1)
    }

    private enum ReadFailure: Error { case checkpoint }

    private final class FailingCheckpointSource: DeviceFileSource {
        let reads = Mutex(0)
        let local: LocalFileSource

        init(root: URL) throws { local = try LocalFileSource(root: root) }
        func probe() -> String { local.probe() }
        func manifest() throws -> DeviceSourceManifest { try local.manifest() }
        func read(_ file: DeviceSourceFile, offset: UInt64, count: Int) throws -> Data {
            let countOfReads = reads.withLock { $0 += 1; return $0 }
            // Fail the tail hash after the stream and prefix hash succeeded.
            if countOfReads == 3 { throw ReadFailure.checkpoint }
            return try local.read(file, offset: offset, count: count)
        }
    }
}
