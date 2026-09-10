import Foundation
import GRDB
import Testing
@testable import TokenTickCore

struct DefaultPricingTests {
    @Test func retiredCodexModelPricesOfflineAndStoredHistoryWins() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        let price = try store.pool.read { try UsageStore.modelPrice(db: $0, model: "gpt-5.2-codex", date: "2025-12-01") }
        #expect(price?.standard.input == Decimal(string: "1.75"))
        #expect(price?.standard.cacheRead == Decimal(string: "0.175"))
        #expect(price?.source.isBundled == true)
        let tokens = TokenUsage(inputTokens: 1_000, outputTokens: 100, cachedInputTokens: 500, cacheWriteInputTokens: 0,
                                reasoningOutputTokens: 0, totalTokens: 1_100)
        #expect(try UsagePricing.calculate(tokens: tokens, isFast: nil, price: price).amount == 2_362_500)
        let missing = Data(#"{"openai":{"models":{"gpt-5.2-codex":{"id":"gpt-5.2-codex"}}}}"#.utf8)
        _ = try store.savePrices(ModelsDevPrices.decode(missing, date: "2026-09-09"), date: "2026-09-09")
        #expect(try store.pool.read { try UsageStore.modelPrice(db: $0, model: "gpt-5.2-codex", date: "2026-09-09") }?.source.isBundled == true)
        let data = Data(#"{"openai":{"models":{"gpt-5.2-codex":{"id":"gpt-5.2-codex","cost":{"input":2,"output":16,"cache_read":0.2}}}}}"#.utf8)
        _ = try store.savePrices(ModelsDevPrices.decode(data, date: "2026-09-10"), date: "2026-09-10")
        let updated = try store.pool.read { try UsageStore.modelPrice(db: $0, model: "gpt-5.2-codex", date: "2026-09-10") }
        #expect(updated?.standard.input == 2 && updated?.source.isBundled != true)
        #expect(try store.pool.read { try UsageStore.modelPrice(db: $0, model: "unpublished-model", date: "2026-09-10") } == nil)
        #expect(try BundledModelPrices.price(model: "gpt-6-astra")?.fastLong.input == 40)
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
