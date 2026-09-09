import Foundation
import GRDB
import Testing
@testable import TokenTickCore

struct SettingsAttributionTests {
    @Test func settingsAndTurnStartPriceUsageBeforeContextAndSurviveRestart() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        _ = try fixture.store.savePrices(ModelsDevPrices.decode(Data(UsagePricingTests.document.utf8), date: "2026-09-09"), date: "2026-09-09")
        try fixture.write(fixture.header + fixture.context("old") + fixture.settings(tier: "priority")
                          + fixture.started("new") + fixture.record(1, turn: "new"))
        #expect(try fixture.scan().insertedRequests == 1)
        var rows = try fixture.rows()
        #expect(rows[0]["model"] as String? == "gpt-6-astra" && rows[0]["is_fast"] as Bool? == true)
        #expect(rows[0]["amount"] as Int64? == 2_920_000)
        let evidence = try #require(JSONSerialization.jsonObject(with: Data((rows[0]["evidence_json"] as String).utf8)) as? [String: Any])
        #expect((evidence["modelSource"] as? [String: Any])?["eventType"] as? String == "thread_settings_applied")
        #expect((evidence["serviceTierSource"] as? [String: Any])?["line"] as? Int == 3)
        #expect(evidence["turnStartedLine"] as? Int == 4)
        try fixture.append(fixture.context("new") + fixture.record(2, turn: "new"))
        let reopened = try UsageStore(databaseURL: fixture.store.databaseURL)
        #expect(try LocalUsageScanner(store: reopened).scan(codexHome: fixture.root).insertedRequests == 1)
        rows = try fixture.rows()
        #expect(rows.allSatisfy { $0["is_fast"] as Bool? == true })
        #expect(rows.reduce(Int64(0)) { $0 + ($1["total_tokens"] as Int64) } == 240)
    }

    @Test func futureSettingsDoNotChangeCurrentTurnAndModelSwitchBeforeContextStaysAmbiguous() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try fixture.write(fixture.header + fixture.settings(tier: "default") + fixture.started("a") + fixture.context("a")
                          + fixture.settings(model: "gpt-5.6-sol", tier: "priority") + fixture.record(1, turn: "a")
                          + fixture.started("b") + fixture.record(2, turn: "b")
                          + fixture.context("b", model: "gpt-5.6-sol") + fixture.record(3, turn: "b")
                          + fixture.record(4, turn: "unrelated"))
        _ = try fixture.scan()
        let rows = try fixture.rows()
        #expect(rows[0]["model"] as String? == "gpt-6-astra" && rows[0]["is_fast"] as Bool? == false)
        #expect(rows[1]["model"] as String? == nil && rows[1]["is_fast"] as Bool? == true)
        #expect((rows[1]["evidence_json"] as String).contains("modelCandidates"))
        #expect(rows[2]["model"] as String? == "gpt-5.6-sol" && rows[2]["is_fast"] as Bool? == true)
        #expect(rows[3]["model"] as String? == nil && rows[3]["is_fast"] as Bool? == nil)
        let mismatch = try #require(JSONSerialization.jsonObject(with: Data((rows[3]["evidence_json"] as String).utf8)) as? [String: Any])
        #expect(mismatch["serviceTier"] == nil && mismatch["serviceTierSource"] == nil)
    }

    @Test func wrongOwnerAndInheritedSnapshotsCannotSetChildModelOrFast() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let header = fixture.event("session_meta", #"{"id":"\#(fixture.thread)","forked_from_id":"parent","subagent_history_start_ordinal":10}"#, ordinal: 0)
        try fixture.write(header + fixture.settings(tier: "priority", owner: nil, ordinal: 1)
                          + fixture.settings(tier: "priority", owner: "parent", ordinal: 11)
                          + fixture.started("new", ordinal: 12) + fixture.record(1, turn: "new", ordinal: 13))
        _ = try fixture.scan()
        let row = try #require(fixture.rows().first)
        #expect(row["model"] as String? == nil && row["is_fast"] as Bool? == nil)
    }

    @Test func missingContextTierPreservesBoundSnapshotButExplicitNullClearsIt() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try fixture.write(fixture.header + fixture.settings(tier: "priority", owner: nil) + fixture.started("new", alias: true)
                          + fixture.context("new") + fixture.record(1, turn: "new")
                          + fixture.context("new", tier: "null") + fixture.record(2, turn: "new"))
        _ = try fixture.scan()
        let rows = try fixture.rows()
        #expect(rows[0]["is_fast"] as Bool? == true)
        #expect(rows[1]["is_fast"] as Bool? == nil)
    }

    @Test func rescanEnrichesOldFactsRepricesInvalidatesCacheAndIsIdempotent() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        _ = try fixture.store.savePrices(ModelsDevPrices.decode(Data(UsagePricingTests.document.utf8), date: "2026-09-09"), date: "2026-09-09")
        try fixture.write(fixture.header + fixture.settings(tier: "priority") + fixture.started("new") + fixture.record(1, turn: "new"))
        _ = try fixture.scan()
        try fixture.store.pool.write { db in
            try db.execute(sql: """
                UPDATE usage SET model = NULL, is_fast = NULL, amount = NULL,
                    evidence_json = json_remove(evidence_json, '$.modelSource', '$.serviceTierSource', '$.threadSettings', '$.turnStartedLine');
                UPDATE scan_files SET parser_state_json = json_set(parser_state_json, '$.version', 1);
                """)
        }
        let before = try #require(fixture.rows().first)
        _ = try fixture.store.rebuildStatistics(timezone: "UTC")
        let report = try fixture.scan()
        #expect(report.insertedRequests == 0 && report.upgradedRequests == 1)
        let after = try #require(fixture.rows().first)
        #expect(after["id"] as Int64 == before["id"] as Int64 && after["total_tokens"] as Int64 == 120)
        #expect(after["model"] as String? == "gpt-6-astra" && after["is_fast"] as Bool? == true)
        #expect(after["amount"] as Int64? == 2_920_000)
        #expect(try fixture.store.pool.read { try !UsageStore.statisticsAreCurrent($0, timezone: "UTC") })
        #expect(try fixture.store.usageReport(UsageQuery(grouping: .total, timezone: "UTC")).rows.first?.knownAmountNanoUSD == 2_920_000)
        #expect(try fixture.scan().unchangedFiles == 1)
        try fixture.store.pool.write { db in try db.execute(sql: "UPDATE scan_files SET parser_state_json = json_set(parser_state_json, '$.version', 1)") }
        #expect(try fixture.scan().upgradedRequests == 0)
        #expect(try fixture.rows() == [after])
    }

    @Test func legacyIdentityFromV1SurvivesCorrectedTurnAttribution() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try fixture.write(fixture.header + fixture.context("old") + fixture.settings(tier: "priority")
                          + fixture.started("new") + fixture.count)
        _ = try fixture.scan()
        let key = "legacy:274399906142e41077ad6503a1ae30be507430670d48467be18f0ec1bd6a449e"
        #expect(try fixture.rows().first?["dedup_key"] as String? == key)
        try fixture.store.pool.write { db in
            try db.execute(sql: """
                UPDATE usage SET turn_id = 'old', is_fast = NULL,
                    evidence_json = json_remove(evidence_json, '$.modelSource', '$.serviceTierSource', '$.threadSettings', '$.turnStartedLine');
                UPDATE scan_files SET parser_state_json = json_set(parser_state_json, '$.version', 1);
                """)
        }
        #expect(try fixture.scan().insertedRequests == 0)
        let row = try #require(fixture.rows().first)
        #expect(row["dedup_key"] as String == key && row["turn_id"] as String? == "new")
        #expect(row["is_fast"] as Bool? == true && (row["evidence_json"] as String).contains("attributionRepair"))
        #expect(try fixture.rows().count == 1)
    }

    @Test func conflictingKnownMetadataRollsBackWithoutOverwritingFacts() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try fixture.write(fixture.header + fixture.settings(tier: "priority") + fixture.started("new") + fixture.record(1, turn: "new"))
        _ = try fixture.scan()
        try fixture.store.pool.write { db in
            try db.execute(sql: "UPDATE usage SET model = 'conflicting-known-model'; UPDATE scan_files SET parser_state_json = json_set(parser_state_json, '$.version', 1)")
        }
        let before = try fixture.rows()
        #expect(throws: (any Error).self) { try fixture.scan() }
        #expect(try fixture.rows() == before)
    }

    private struct Fixture {
        let root: URL
        let store: UsageStore
        let thread = "00000000-0000-0000-0000-000000000008"
        var file: URL { root.appendingPathComponent("sessions/rollout-2026-09-09T00-00-00-\(thread).jsonl") }
        var header: String { event("session_meta", #"{"id":"\#(thread)"}"#) }
        var tokens: String { #"{"input_tokens":100,"cached_input_tokens":60,"cache_write_input_tokens":0,"output_tokens":20,"reasoning_output_tokens":12,"total_tokens":120}"# }
        var count: String { event("event_msg", #"{"type":"token_count","info":{"total_token_usage":\#(tokens),"last_token_usage":\#(tokens)}}"#) }
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
            store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        }
        func event(_ type: String, _ payload: String, ordinal: Int? = nil) -> String {
            "{\"timestamp\":\"2026-09-09T00:00:01Z\",\(ordinal.map { "\"ordinal\":\($0)," } ?? "")\"type\":\"\(type)\",\"payload\":\(payload)}\n"
        }
        func settings(model: String = "gpt-6-astra", tier: String, owner: String? = "00000000-0000-0000-0000-000000000008", ordinal: Int? = nil) -> String {
            event("event_msg", "{\"type\":\"thread_settings_applied\",\(owner.map { "\"thread_id\":\"\($0)\"," } ?? "")\"thread_settings\":{\"model\":\"\(model)\",\"service_tier\":\"\(tier)\",\"model_provider_id\":\"openai\"}}", ordinal: ordinal)
        }
        func started(_ turn: String, ordinal: Int? = nil, alias: Bool = false) -> String {
            event("event_msg", #"{"type":"\#(alias ? "turn_started" : "task_started")","turn_id":"\#(turn)"}"#, ordinal: ordinal)
        }
        func context(_ turn: String, model: String = "gpt-6-astra", tier: String? = nil) -> String {
            event("turn_context", "{\"turn_id\":\"\(turn)\",\"model\":\"\(model)\"\(tier.map { ",\"service_tier\":\($0)" } ?? "")}")
        }
        func record(_ index: Int, turn: String, ordinal: Int? = nil) -> String {
            event("token_usage_record", #"{"thread_id":"\#(thread)","turn_id":"\#(turn)","response_id":"r-\#(index)","usage":\#(tokens),"thread_token_usage":\#(tokens)}"#, ordinal: ordinal)
        }
        func write(_ text: String) throws { try Data(text.utf8).write(to: file) }
        func append(_ text: String) throws {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: Data(text.utf8))
        }
        func scan() throws -> ScanReport { try LocalUsageScanner(store: store).scan(codexHome: root) }
        func rows() throws -> [Row] { try store.pool.read { try Row.fetchAll($0, sql: "SELECT * FROM usage ORDER BY id") } }
        func clean() { try? FileManager.default.removeItem(at: root) }
    }
}
