import Foundation
import GRDB
import Testing
@testable import TokenTickCore

struct RepriceRecoveryTests {
    @Test func completedBatchesResumeAfterReopeningAndReportTheWholeOperation() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try fixture.interruptAfterFirstBatch()
        #expect(try fixture.pricedCount() == 512)
        try fixture.store.pool.write { db in try db.execute(sql: "DROP TRIGGER interrupt_reprice") }
        let reopened = try UsageStore(databaseURL: fixture.store.databaseURL)
        let report = try reopened.repriceUsage()
        #expect(report.examined == 1025)
        #expect(report.changed == 1025)
        #expect(report.fullyPriced == 1025)
        #expect(try fixture.pricedCount() == 1025)
        #expect(try fixture.checkpointCount() == 0)
        let repeated = try reopened.repriceUsage()
        #expect(repeated.examined == 1025 && repeated.changed == 0)
    }

    @Test func checkpointFailureRollsBackAmountsAndFactRevision() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let revision = try fixture.store.pool.read { try UsageStore.statisticsRevision($0) }
        try fixture.store.pool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_checkpoint BEFORE INSERT ON app_metadata
                WHEN NEW.key = 'reprice_checkpoint'
                BEGIN SELECT RAISE(ABORT, 'checkpoint fixture failure'); END
                """)
        }
        #expect(throws: (any Error).self) { try fixture.store.repriceUsage() }
        #expect(try fixture.pricedCount() == 0)
        #expect(try fixture.checkpointCount() == 0)
        #expect(try fixture.store.pool.read { try UsageStore.statisticsRevision($0) } == revision)
        try fixture.store.pool.write { db in try db.execute(sql: "DROP TRIGGER reject_checkpoint") }
        #expect(try fixture.store.repriceUsage().changed == 1025)
    }

    @Test(arguments: ["facts", "prices", "scope", "version", "corrupt"])
    func changedInputsAndIncompatibleCheckpointsRestartSafely(change: String) throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try fixture.interruptAfterFirstBatch()
        try fixture.store.pool.write { db in
            try db.execute(sql: "DROP TRIGGER interrupt_reprice")
            switch change {
            case "facts":
                try db.execute(sql: "UPDATE usage SET input_tokens = input_tokens + 1, total_tokens = total_tokens + 1 WHERE id = 1")
            case "prices":
                try db.execute(sql: "UPDATE prices SET input_price = '12'")
            case "version":
                try db.execute(sql: "UPDATE app_metadata SET value = json_set(value, '$.version', 0) WHERE key = 'reprice_checkpoint'")
            case "corrupt":
                try db.execute(sql: "UPDATE app_metadata SET value = 'invalid checkpoint JSON' WHERE key = 'reprice_checkpoint'")
            default: break
            }
        }
        let report = try fixture.store.repriceUsage(fromDate: change == "scope" ? "2026-09-09" : nil)
        #expect(report.examined == 1025)
        #expect(report.changed == (change == "prices" ? 1025 : change == "facts" ? 514 : 513))
        let firstAmount = try fixture.store.pool.read { try Int64.fetchOne($0, sql: "SELECT amount FROM usage WHERE id = 1") }
        #expect(firstAmount == (change == "prices" ? 10_500_000 : change == "facts" ? 10_110_000 : 10_100_000))
        #expect(try fixture.pricedCount() == 1025)
        #expect(try fixture.checkpointCount() == 0)
    }

    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store: UsageStore

        init() throws {
            store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
            _ = try store.savePrices(ModelsDevPrices.decode(Data(UsagePricingTests.document.utf8), date: "2026-09-09"), date: "2026-09-09")
            try store.pool.write { db in
                for index in 1...1025 {
                    try db.execute(sql: """
                        INSERT INTO usage(source_line,rollout_id, usage_date, model, tier, input_tokens, output_tokens,
                            cache_read_tokens, cache_write_tokens, reasoning_tokens, total_tokens, source, pricing_source)
                        VALUES (1,?, '2026-09-09', 'gpt-6-astra', 'standard', 1000, 100, 600, 200, 80, 1100, 'local', '{}')
                        """, arguments: ["fixture-\(index)"])
                }
            }
        }

        func interruptAfterFirstBatch() throws {
            try store.pool.write { db in
                try db.execute(sql: """
                    CREATE TRIGGER interrupt_reprice BEFORE UPDATE OF amount ON usage WHEN OLD.id > 512
                    BEGIN SELECT RAISE(ABORT, 'second batch fixture failure'); END
                    """)
            }
            #expect(throws: (any Error).self) { try store.repriceUsage() }
            #expect(try checkpointCount() == 1)
        }

        func pricedCount() throws -> Int {
            try store.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM usage WHERE amount IS NOT NULL") ?? 0 }
        }

        func checkpointCount() throws -> Int {
            try store.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM app_metadata WHERE key = 'reprice_checkpoint'") ?? 0 }
        }

        func clean() { try? FileManager.default.removeItem(at: root) }
    }
}
