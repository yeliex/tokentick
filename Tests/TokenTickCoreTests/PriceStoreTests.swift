import Foundation
import GRDB
import Testing
@testable import TokenTickCore

struct PriceStoreTests {
    @Test func dailySnapshotsOnlyRecordPriceChangesAndKeepHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        func save(_ date: String, json: String = UsagePricingTests.document) throws -> PriceSyncReport {
            try store.savePrices(ModelsDevPrices.decode(Data(json.utf8), date: date), date: date)
        }
        #expect(try save("2026-09-09").insertedSnapshots == 1)
        #expect(try save("2026-09-10", json: UsagePricingTests.document.replacingOccurrences(of: "标题不参与价格比较", with: "新标题")).insertedSnapshots == 0)
        let changed = UsagePricingTests.document.replacingOccurrences(of: #""input":10,"output""#, with: #""input":12,"output""#)
        #expect(try save("2026-09-11", json: changed).insertedSnapshots == 1)
        #expect(try save("2026-09-11").alreadySynced)
        #expect(try store.tableCounts()["prices"] == 2)
        try store.pool.read { db throws -> Void in
            #expect(try UsageStore.modelPrice(db: db, model: "gpt-6-astra", date: "2026-09-08")?.standard.input == 10)
            #expect(try UsageStore.modelPrice(db: db, model: "gpt-6-astra", date: "2026-09-10")?.standard.input == 10)
            #expect(try UsageStore.modelPrice(db: db, model: "gpt-6-astra", date: "2026-09-12")?.standard.input == 12)
        }
    }

    @Test func firstSnapshotPricesEarlierRequestsWithoutChangingFacts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        let prices = try ModelsDevPrices.decode(Data(UsagePricingTests.document.utf8), date: "2026-09-09")
        _ = try store.savePrices(prices, date: "2026-09-09")
        try store.pool.write { db in
            for date in ["2026-09-08", "2026-09-09"] {
                try db.execute(sql: """
                    INSERT INTO usage(dedup_key, usage_date, model, is_fast, input_tokens, output_tokens,
                        cache_read_tokens, cache_write_tokens, reasoning_tokens, total_tokens, source, evidence_json)
                    VALUES (?, ?, 'gpt-6-astra', 0, 1000, 100, 600, 200, 80, 1100, 'local', '{}')
                    """, arguments: [date, date])
            }
        }
        #expect(try store.needsRepricing())
        let first = try store.repriceUsage()
        #expect(try !store.needsRepricing())
        #expect(first.examined == 2)
        #expect(first.fullyPriced == 2)
        #expect(first.unpriced == 0)
        #expect(try store.repriceUsage().changed == 0)
        try store.pool.read { db throws -> Void in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM usage ORDER BY usage_date")
            #expect(rows[0]["amount"] as Int64? == 10_100_000)
            #expect(rows[1]["amount"] as Int64? == 10_100_000)
            #expect(rows[1]["input_price"] as String? == "10")
            #expect(rows[1]["cache_write_amount"] as Int64? == 2_500_000)
            #expect(try Int64.fetchOne(db, sql: "SELECT SUM(total_tokens) FROM usage") == 2200)
            #expect(try String.fetchOne(db, sql: "SELECT value FROM app_metadata WHERE key = 'statistics_dirty'") == "true")
        }
    }

    @Test func invalidUsageClearsStaleAmountWithoutDeletingEvidence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        try store.pool.write { db in
            try db.execute(sql: """
                INSERT INTO usage(dedup_key, usage_date, input_tokens, output_tokens, cache_read_tokens,
                    cache_write_tokens, total_tokens, amount, source, evidence_json)
                VALUES ('invalid', '2026-09-09', 100, 10, 120, 0, 110, 999, 'local', '{"reason":"fixture"}')
                """)
        }
        #expect(try store.repriceUsage().invalidUsage == 1)
        try store.pool.read { db throws -> Void in
            let row = try #require(try Row.fetchOne(db, sql: "SELECT * FROM usage"))
            #expect(row["amount"] as Int64? == nil)
            #expect(row["total_tokens"] as Int64 == 110)
            let proof = try JSONSerialization.jsonObject(with: Data((row["evidence_json"] as String).utf8)) as? [String: Any]
            #expect(proof?["reason"] as? String == "fixture")
        }
    }

    @Test func failedPriceDecodeDoesNotMarkDaySuccessful() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        _ = try store.savePrices(ModelsDevPrices.decode(Data(UsagePricingTests.document.utf8), date: "2026-09-09"), date: "2026-09-09")
        #expect(throws: (any Error).self) {
            let prices = try ModelsDevPrices.decode(Data("{}".utf8), date: "2026-09-10")
            _ = try store.savePrices(prices, date: "2026-09-10")
        }
        #expect(try !store.hasSyncedPrices(on: "2026-09-10"))
        #expect(try store.tableCounts()["prices"] == 1)
    }

    @Test(arguments: ["default", "priority", "fast"]) func newlyScannedRequestUsesExistingPriceAndQueriesKeepPartialAmounts(tier: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        _ = try store.savePrices(ModelsDevPrices.decode(Data(UsagePricingTests.document.utf8), date: "2026-09-09"), date: "2026-09-09")
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let id = "00000000-0000-0000-0000-000000000005"
        let counters = #"{"input_tokens":1000,"output_tokens":100,"cached_input_tokens":600,"cache_write_input_tokens":200,"reasoning_output_tokens":80,"total_tokens":1100}"#
        let text = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(id)\"}}\n"
            + "{\"type\":\"turn_context\",\"payload\":{\"turn_id\":\"t\",\"model\":\"gpt-6-astra\",\"service_tier\":\"\(tier)\"}}\n"
            + "{\"timestamp\":\"2026-09-09T00:00:01Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":\(counters),\"last_token_usage\":\(counters)}}}\n"
        try Data(text.utf8).write(to: sessions.appendingPathComponent("rollout-2026-09-09T00-00-00-\(id).jsonl"))
        #expect(try LocalUsageScanner(store: store).scan(codexHome: root).insertedRequests == 1)
        let factor: Int64 = tier == "default" ? 1 : 2
        #expect(try store.usageSummaries().first?.knownAmountNanoUSD == 10_100_000 * factor)
        #expect(try store.repriceUsage().changed == 0)
        try store.pool.write { db in
            try db.execute(sql: "UPDATE usage SET cache_write_tokens = NULL, is_fast = NULL")
        }
        #expect(try store.repriceUsage().partiallyPriced == 1)
        #expect(try store.usageSummaries().first?.knownAmountNanoUSD == 5_600_000 * factor)
        #expect(try store.usageSummaries().first?.unpricedTokens == 1100)
    }

}
