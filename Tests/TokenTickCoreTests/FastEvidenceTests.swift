import Foundation
import GRDB
import Testing
@testable import TokenTickCore

struct FastEvidenceTests {
    static let thread = "00000000-0000-0000-0000-000000000001"
    static let turn = "00000000-0000-0000-0000-000000000002"

    @Test func chatGPTAuthenticationRemovesLongContextRatesForTheMatchingTurn() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        let trace = try DatabaseQueue(path: root.appendingPathComponent("logs_2.sqlite").path)
        let prefix = "run_sampling_request{turn_id=\(Self.turn)}: endpoint=\"/responses\" auth_header_attached=true "
        try await trace.write { db in
            try db.execute(sql: "CREATE TABLE logs(id INTEGER PRIMARY KEY,ts INTEGER,thread_id TEXT,target TEXT,feedback_log_body TEXT)")
            try db.execute(sql: "INSERT INTO logs VALUES (1,100,?,'feedback_tags',?)",
                arguments: [Self.thread, prefix + "auth_mode=\"Chatgpt\" auth_error=\"\" private-diagnostic"])
        }
        try await store.pool.write { db in
            try db.execute(sql: """
                INSERT INTO usage(source_line,rollout_id,thread_id,turn_id,turn_key,total_tokens,input_tokens,output_tokens,cache_read_tokens,
                    cache_write_tokens,model,tier,usage_date,source)
                    VALUES (1,'a',?,?,?,300000,300000,0,0,0,'gpt-6-astra','fast','2026-09-10','local'),
                           (1,'b',?,'other','turn:other',300000,300000,0,0,0,'gpt-6-astra','fast','2026-09-10','local')
                """, arguments: [Self.thread, Self.turn, "turn:" + Self.turn, Self.thread])
        }
        _ = try store.repriceUsage()
        let page = try DeviceTracePage.read(root: root, file: "logs_2.sqlite", previous: nil)
        #expect(page.entries.first?.body == "")
        _ = try await LocalUsageScanner(store: store).scan(codexHome: root)
        let records = try store.usageRecords().rows
        let chatGPT = records.first { $0.turnID == Self.turn }
        #expect(chatGPT?.billingMode == "plan")
        #expect(chatGPT?.isLongContext == false && chatGPT?.inputPrice == "20")
        #expect(chatGPT?.amountNanoUSD == 6_000_000_000)
        #expect(chatGPT?.apiAmountNanoUSD == 12_000_000_000)
        #expect(records.first { $0.turnID == "other" }?.inputPrice == "40")
        try await trace.write { db in
            try db.execute(sql: "INSERT INTO logs VALUES (2,101,?,'feedback_tags',?)",
                arguments: [Self.thread, prefix + "auth_mode=\"ApiKey\" auth_error=\"\""])
        }
        _ = try await LocalUsageScanner(store: store).scan(codexHome: root)
        let mixed = try store.usageRecords().rows.first { $0.turnID == Self.turn }
        #expect(mixed?.billingMode == "api" && mixed?.inputPrice == "40")
    }

    @Test func traceBackfillsExistingUsageAndIncrementalReplayKeepsFacts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        try await store.pool.write { db in
            for (key, fast) in [("missing", nil as Bool?), ("ordinary", false)] {
                try db.execute(sql: """
                    INSERT INTO usage(source_line,rollout_id,thread_id,turn_id,model,usage_date,tier,input_tokens,output_tokens,
                      cache_read_tokens,cache_write_tokens,total_tokens,source,pricing_source)
                    VALUES (1,?,?,?,'gpt-6-astra','2026-09-10',?,1000,100,500,0,1100,'local','{"keep":true}')
                    """, arguments: [key, Self.thread, Self.turn, fast.map { $0 ? "fast" : "standard" }])
            }
        }
        #expect(try store.repriceUsage().fullyPriced == 2)
        let before = try store.usageRecords().rows
        #expect(before.allSatisfy { $0.amountNanoUSD == 10_500_000 })
        let trace = try DatabaseQueue(path: root.appendingPathComponent("logs_2.sqlite").path)
        try await trace.write { try $0.execute(sql: "CREATE TABLE logs(id INTEGER PRIMARY KEY,ts INTEGER,thread_id TEXT,feedback_log_body TEXT)") }
        let body = "session_loop{thread_id=\(Self.thread)}:turn{turn.id=\(Self.turn)}: websocket request: "
            + #"{"type":"response.create","service_tier":"priority","input":"private-user-body"}"#
        try await trace.write { try $0.execute(sql: "INSERT INTO logs VALUES (1,100,?,?)", arguments: [Self.thread, body]) }
        _ = try await LocalUsageScanner(store: store).scan(codexHome: root)
        let after = try store.usageRecords().rows
        #expect(after.first(where: { $0.isFast == nil })?.amountNanoUSD == 21_000_000)
        #expect(after.first(where: { $0.isFast == false })?.amountNanoUSD == 10_500_000)
        #expect(after.first(where: { $0.isFast == nil })?.pricingIsFast == true)
        #expect(after.map(\.totalTokens) == before.map(\.totalTokens))
        let revision = try store.status().factsRevision
        _ = try await LocalUsageScanner(store: store).scan(codexHome: root)
        #expect(try store.status().factsRevision == revision)
        let values = try await store.pool.read { try String.fetchAll($0, sql: "SELECT value FROM app_metadata UNION ALL SELECT pricing_source FROM usage") }
        #expect(!values.contains(where: { $0.contains("private-user-body") }))
        // Detect anchor changes when a truncated file reuses row IDs at the same path.
        try await trace.write { db in
            try db.execute(sql: "DELETE FROM logs; INSERT INTO logs VALUES (1,101,?,?)", arguments: [Self.thread, body.replacingOccurrences(of: Self.turn, with: "00000000-0000-0000-0000-000000000003")])
        }
        _ = try await LocalUsageScanner(store: store).scan(codexHome: root)
        #expect(try await store.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM app_metadata WHERE key LIKE 'fast_trace:%'") } == 2)
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
