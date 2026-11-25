import Foundation
import GRDB
import Testing
@testable import TokenTickCore

struct DefaultPricingTests {
    @Test func bundledAutoReviewIsFreeAcrossServiceTiers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        try store.pool.write { db in
            try db.execute(sql: """
                INSERT INTO usage(model, usage_date, tier, billing_mode, input_tokens, output_tokens,
                    cache_read_tokens, cache_write_tokens, total_tokens, source, rollout_id, source_line)
                VALUES ('codex-auto-review', '2026-11-24', NULL, 'plan', 10, 4, 2, 1, 14, 'local', 'review', 1),
                       ('codex-auto-review', '2026-11-24', 'fast', 'plan', 10, 4, 2, 1, 14, 'local', 'review', 2),
                       ('codex-auto-review', '2026-11-24', 'ultrafast', 'plan', 10, 4, NULL, NULL, 14, 'local', 'review', 3)
                """)
        }
        #expect(try store.repriceUsage().fullyPriced == 3)
        let rows = try store.usageRecords().rows
        #expect(rows.count == 3)
        #expect(rows.allSatisfy { $0.totalTokens == 14 && $0.amountNanoUSD == 0 && $0.apiAmountNanoUSD == 0 })
        #expect(Set(rows.compactMap(\.pricingTier)) == ["standard", "fast", "ultrafast"])
    }

    @Test func subscriptionAndAPIAmountsSurviveRepricingAndAggregation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        try store.pool.write { db in
            try db.execute(sql: """
                INSERT INTO usage(model,usage_date,tier,billing_mode,input_tokens,output_tokens,cache_read_tokens,cache_write_tokens,
                    total_tokens,source,rollout_id,source_line)
                VALUES ('gpt-6-astra','2026-11-02','fast','plan',406199,1955,405888,0,408154,'local','one',1)
                """)
        }
        _ = try store.repriceUsage()
        let record = try #require(try store.usageRecords().rows.first)
        #expect(record.amountNanoUSD == 1_013_496_000 && record.apiAmountNanoUSD == 1_929_242_000)
        _ = try store.rebuildStatistics(timezone: "UTC")
        let summary = try #require(try store.usageReport(UsageQuery(timezone: "UTC")).rows.first)
        #expect(summary.knownAmountNanoUSD == record.amountNanoUSD)
        #expect(summary.apiKnownAmountNanoUSD == record.apiAmountNanoUSD && summary.apiUnpricedRecords == 0)
        let overview = try store.overviewReport(period: .all, now: Date(), timezone: "UTC")
        #expect(overview.modes.map(\.name) == ["fast"])
        #expect(overview.apiModes.map(\.name) == ["fast_long_context"])
        #expect(overview.modes.first?.amount == 1_013_496_000)
        #expect(overview.apiModes.first?.apiAmount == 1_929_242_000)
    }

    @Test func retiredCodexModelPricesOfflineAndStoredHistoryWins() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        let price = try store.pool.read { try UsageStore.modelPrice(db: $0, model: "gpt-5.2-codex", date: "2025-12-01") }
        #expect(price?.rates.input == Decimal(string: "1.75"))
        #expect(price?.rates.cacheRead == Decimal(string: "0.175"))
        #expect(price?.source.isBundled == true)
        let tokens = TokenUsage(inputTokens: 1_000, outputTokens: 100, cachedInputTokens: 500, cacheWriteInputTokens: 0,
                                reasoningOutputTokens: 0, totalTokens: 1_100)
        #expect(try UsagePricing.calculate(tokens: tokens, price: price).amount == 2_362_500)
        let missing = UsagePricingTests.price(model: "gpt-5.2-codex", rates: .unknown)
        _ = try store.savePrices([missing], date: "2026-09-09")
        #expect(try store.pool.read { try UsageStore.modelPrice(db: $0, model: "gpt-5.2-codex", date: "2026-09-09") }?.source.isBundled == true)
        let priceUpdate = UsagePricingTests.price(model: "gpt-5.2-codex", date: "2026-09-10",
                                                 rates: PriceRates(input: 2, output: 16, cacheRead: 0.2))
        _ = try store.savePrices([priceUpdate], date: "2026-09-10")
        let updated = try store.pool.read { try UsageStore.modelPrice(db: $0, model: "gpt-5.2-codex", date: "2026-09-10") }
        #expect(updated?.rates.input == 2 && updated?.source.isBundled != true)
        #expect(try store.pool.read { try UsageStore.modelPrice(db: $0, model: "unpublished-model", date: "2026-09-10") } == nil)
        #expect(try BundledModelPrices.price(model: "gpt-6-astra", tier: "fast")?.long.input == 40)
    }

    @Test func failedMigrationRollsBackWithoutCreatingBackup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("usage.sqlite")
        let old = try DatabaseQueue(path: url.path)
        try old.write { try $0.execute(sql: "CREATE TABLE usage(value TEXT); INSERT INTO usage VALUES ('retain')") }
        #expect(throws: (any Error).self) { try UsageStore(databaseURL: url) }
        try old.read { db throws -> Void in
            #expect(try String.fetchOne(db, sql: "SELECT value FROM usage") == "retain")
            #expect(try !db.tableExists("threads"))
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Backups").path))
    }
}
