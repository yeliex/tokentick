import Foundation
import GRDB
import Testing
@testable import TokenTickCore

struct FastEvidenceTests {
    static let thread = "00000000-0000-0000-0000-000000000001"
    static let turn = "00000000-0000-0000-0000-000000000002"

    @Test func traceBackfillsExistingUsageAndIncrementalReplayKeepsFacts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        try store.pool.write { db in
            for (key, fast) in [("missing", nil as Bool?), ("ordinary", false)] {
                try db.execute(sql: """
                    INSERT INTO usage(dedup_key,thread_id,turn_id,model,usage_date,is_fast,input_tokens,output_tokens,
                      cache_read_tokens,cache_write_tokens,total_tokens,source,evidence_json)
                    VALUES (?,?,?,'gpt-6-astra','2026-09-10',?,1000,100,500,0,1100,'local','{"keep":true}')
                    """, arguments: [key, Self.thread, Self.turn, fast])
            }
        }
        #expect(try store.repriceUsage().fullyPriced == 2)
        let before = try store.usageRecords().rows
        #expect(before.allSatisfy { $0.amountNanoUSD == 10_500_000 })
        let trace = try DatabaseQueue(path: root.appendingPathComponent("logs_2.sqlite").path)
        try trace.write { try $0.execute(sql: "CREATE TABLE logs(id INTEGER PRIMARY KEY,ts INTEGER,thread_id TEXT,feedback_log_body TEXT)") }
        let body = "session_loop{thread_id=\(Self.thread)}:turn{turn.id=\(Self.turn)}: websocket request: "
            + #"{"type":"response.create","service_tier":"priority","input":"private-user-body"}"#
        try trace.write { try $0.execute(sql: "INSERT INTO logs VALUES (1,100,?,?)", arguments: [Self.thread, body]) }
        try CodexFastEvidence.collect(codexHome: root, store: store)
        let after = try store.usageRecords().rows
        #expect(after.first(where: { $0.isFast == nil })?.amountNanoUSD == 21_000_000)
        #expect(after.first(where: { $0.isFast == false })?.amountNanoUSD == 10_500_000)
        #expect(after.first(where: { $0.isFast == nil })?.pricingIsFast == true)
        #expect(after.map(\.totalTokens) == before.map(\.totalTokens))
        let revision = try store.status().factsRevision
        try CodexFastEvidence.collect(codexHome: root, store: store)
        #expect(try store.status().factsRevision == revision)
        let values = try store.pool.read { try String.fetchAll($0, sql: "SELECT value FROM app_metadata UNION ALL SELECT evidence_json FROM usage") }
        #expect(!values.contains(where: { $0.contains("private-user-body") }))
        // 同路径清空后 row ID 被复用，必须通过锚点变化重新核对。
        try trace.write { db in
            try db.execute(sql: "DELETE FROM logs; INSERT INTO logs VALUES (1,101,?,?)", arguments: [Self.thread, body.replacingOccurrences(of: Self.turn, with: "00000000-0000-0000-0000-000000000003")])
        }
        try CodexFastEvidence.collect(codexHome: root, store: store)
        #expect(try store.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM app_metadata WHERE key LIKE 'fast_trace:%'") } == 2)
    }

    @Test func onlyOwnedTurnAndTopLevelModeProvideEvidence() {
        func parse(_ body: String, thread: String? = Self.thread) -> CodexFastEvidence? {
            CodexFastEvidence.parse(body: body, threadID: thread, fileName: "logs_2.sqlite", rowID: 1, timestamp: 100)
        }
        let prefix = "session_loop{thread_id=\(Self.thread)}: Submission sub=Submission { id: \"\(Self.turn)\", op: "
        #expect(parse(prefix + #"TurnInput { service_tier: Some(Some("fast")) } }"#)?.turnID == Self.turn)
        #expect(parse(prefix + #"ThreadSettings { service_tier: Some(Some("priority")) } }"#) == nil)
        #expect(parse(prefix + #"TurnInput { text: "service_tier: Some(Some(\"priority\"))", service_tier: None } }"#) == nil)
        let request = "thread_id=\(Self.thread) turn_id=\(Self.turn) websocket request: "
        #expect(parse(request + #"{"type":"response.create","service_tier":"default","input":{"service_tier":"priority"}}"#) == nil)
        #expect(parse(request + #"{"type":"response.create","service_tier":"priority"}"#, thread: Self.turn) == nil)
    }
}
