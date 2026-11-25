import Foundation
import GRDB
import Testing
@testable import TokenTickCore

struct PriceStoreTests {
    @Test func structuredPricesRoundTripWithoutSourceJSON() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        let unsupported = UsagePricingTests.price(model: "m", rates: PriceRates(input: 1, output: 2), rule: .unsupported)
        let prices = UsagePricingTests.prices() + [unsupported]
        _ = try store.savePrices(prices, date: "2026-09-09")
        let reopened = try UsageStore(databaseURL: store.databaseURL)
        try await reopened.pool.read { db in
            #expect(try db.columns(in: "prices").allSatisfy { !$0.name.contains("json") })
            for price in prices {
                let stored = try UsageStore.modelPrice(db: db, model: price.model, date: price.date, tier: price.tier, useDefaults: false)
                #expect(stored == price)
            }
        }
    }

    @Test func dailySnapshotsOnlyRecordPriceChangesAndKeepHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        func save(_ date: String, input: Decimal = 10) throws -> PriceSyncReport {
            try store.savePrices(UsagePricingTests.prices(date: date, input: input), date: date)
        }
        #expect(try save("2026-09-09").insertedSnapshots == 2)
        #expect(try save("2026-09-10").insertedSnapshots == 0)
        #expect(try save("2026-09-11", input: 12).insertedSnapshots == 2)
        #expect(try save("2026-09-11").alreadySynced)
        #expect(try store.tableCounts()["prices"] == 4)
        try await store.pool.read { db throws -> Void in
            #expect(try UsageStore.modelPrice(db: db, model: "gpt-6-astra", date: "2026-09-08", useDefaults: false) == nil)
            #expect(try UsageStore.modelPrice(db: db, model: "gpt-6-astra", date: "2026-09-10")?.rates.input == 10)
            #expect(try UsageStore.modelPrice(db: db, model: "gpt-6-astra", date: "2026-09-12")?.rates.input == 12)
        }
    }

    @Test func tiersHaveIndependentHistoryAndPreserveEarlierLongPrices() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        let first = UsagePricingTests.prices()
        _ = try store.savePrices(first.filter { $0.tier == "standard" }, date: "2026-09-09")
        let next = UsagePricingTests.prices(date: "2026-09-10")
        #expect(try store.savePrices(next, date: "2026-09-10").insertedSnapshots == 1)
        let changed = UsagePricingTests.prices(date: "2026-09-11", longInput: 30)
        #expect(try store.savePrices(changed, date: "2026-09-11").insertedSnapshots == 2)
        try await store.pool.read { db throws -> Void in
            let old = try UsageStore.modelPrice(db: db, model: "gpt-6-astra", date: "2026-09-10", tier: "fast")
            #expect(old?.date == "2026-09-10" && old?.long.input == 40)
            let new = try UsageStore.modelPrice(db: db, model: "gpt-6-astra", date: "2026-09-11", tier: "fast")
            #expect(new?.rates.input == 20 && new?.long.input == 60 && new?.long.output == 150)
        }
    }



    @Test func migratedLegacySnapshotPricesEarlierRequestsWithoutChangingFacts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("usage.sqlite")
        let legacy = try DatabaseQueue(path: url.path)
        try StoreSchema.migrator.migrate(legacy, upTo: "api-context-tier.1")
        try await legacy.write { db in
            try db.execute(sql: """
                INSERT INTO prices(model,date,tier,input_price,output_price,cache_read_price,cache_write_price,context_rule,source_url)
                VALUES ('gpt-6-astra','2026-09-09','standard','10','50','1','12.5','uniform','https://models.dev/api.json');
                INSERT INTO app_metadata(key,value) VALUES ('prices_last_success_date','2026-09-09');
                """)
        }
        try legacy.close()
        let store = try UsageStore(databaseURL: url)
        #expect(try !store.hasSyncedPrices(on: "2026-09-09"))
        #expect(try await store.pool.read { try Double.fetchOne($0, sql: "SELECT effective_at FROM prices") } == 1_788_912_000)
        try await store.pool.write { db in
            for date in ["2026-09-08", "2026-09-09"] {
                try db.execute(sql: """
                    INSERT INTO usage(source_line,rollout_id, usage_date, model, tier, input_tokens, output_tokens,
                        cache_read_tokens, cache_write_tokens, reasoning_tokens, total_tokens, source, pricing_source)
                    VALUES (1,?, ?, 'gpt-6-astra', 'standard', 1000, 100, 600, 200, 80, 1100, 'local', '{}')
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
        try await store.pool.read { db throws -> Void in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM usage ORDER BY usage_date")
            #expect(rows[0]["amount"] as Int64? == 10_100_000)
            #expect(rows[1]["amount"] as Int64? == 10_100_000)
            #expect(rows[1]["input_price"] as String? == "10")
            #expect(rows[1]["cache_write_amount"] as Int64? == 2_500_000)
            #expect(try Int64.fetchOne(db, sql: "SELECT SUM(total_tokens) FROM usage") == 2200)
            #expect(try String.fetchOne(db, sql: "SELECT value FROM app_metadata WHERE key = 'statistics_dirty'") == "true")
        }
    }

    @Test func invalidUsageClearsStaleAmountWithoutChangingTokens() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        try await store.pool.write { db in
            try db.execute(sql: """
                INSERT INTO usage(source_line,rollout_id, usage_date, input_tokens, output_tokens, cache_read_tokens,
                    cache_write_tokens, total_tokens, amount, source, pricing_source)
                VALUES (1,'invalid', '2026-09-09', 100, 10, 120, 0, 110, 999, 'local', '{"reason":"fixture"}')
                """)
        }
        #expect(try store.repriceUsage().invalidUsage == 1)
        try await store.pool.read { db throws -> Void in
            let row = try #require(try Row.fetchOne(db, sql: "SELECT * FROM usage"))
            #expect(row["amount"] as Int64? == nil)
            #expect(row["total_tokens"] as Int64 == 110)
        }
    }

    @Test func failedPriceDecodeDoesNotMarkDaySuccessful() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        _ = try store.savePrices(UsagePricingTests.prices(), date: "2026-09-09")
        #expect(throws: (any Error).self) {
            let instant = try #require(DateParsing.parseTimestamp("2026-09-10T00:00:00Z"))
            let prices = try ModelsDevPricesV2.decode(Data("{}".utf8), observedAt: instant)
            _ = try store.savePrices(prices, date: "2026-09-10")
        }
        #expect(try !store.hasSyncedPrices(on: "2026-09-10"))
        #expect(try store.tableCounts()["prices"] == 2)
    }

    @Test(arguments: ["default", "priority", "fast"]) func newlyScannedRequestUsesExistingPriceAndQueriesKeepPartialAmounts(tier: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        _ = try store.savePrices(UsagePricingTests.prices(), date: "2026-09-09")
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let id = "00000000-0000-0000-0000-000000000005"
        let counters = #"{"input_tokens":1000,"output_tokens":100,"cached_input_tokens":600,"cache_write_input_tokens":200,"reasoning_output_tokens":80,"total_tokens":1100}"#
        let text = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(id)\"}}\n"
            + "{\"type\":\"turn_context\",\"payload\":{\"turn_id\":\"t\",\"model\":\"gpt-6-astra\",\"service_tier\":\"\(tier)\"}}\n"
            + "{\"timestamp\":\"2026-09-09T00:00:01Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":\(counters),\"last_token_usage\":\(counters)}}}\n"
        try Data(text.utf8).write(to: sessions.appendingPathComponent("rollout-2026-09-09T00-00-00-\(id).jsonl"))
        #expect(try await LocalUsageScanner(store: store).scan(codexHome: root).insertedRequests == 1)
        let factor: Int64 = tier == "default" ? 1 : 2
        #expect(try store.usageSummaries().first?.knownAmountNanoUSD == 10_100_000 * factor)
        #expect(try store.repriceUsage().changed == 0)
        try await store.pool.write { db in
            try db.execute(sql: "UPDATE usage SET cache_write_tokens = NULL, tier = NULL")
        }
        #expect(try store.repriceUsage().partiallyPriced == 1)
        #expect(try store.usageSummaries().first?.knownAmountNanoUSD == 5_600_000)
        #expect(try store.usageSummaries().first?.unpricedTokens == 1100)
    }

}
