import Foundation
import GRDB
import Testing
@testable import TokenTickCore

struct StatisticsRecoveryTests {
    @Test func interruptedBatchesResumeWithoutPublishingPartialResults() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let before = try fixture.cache()
        try fixture.interruptAfterFirstBatch()
        #expect(try fixture.cache() == before)
        #expect(try fixture.stagedRecords() == 8192)
        let query = try fixture.store.pool.read { db in
            try UsageStore.readUsageReport(UsageQuery(grouping: .total, timezone: "UTC"),
                                           timezone: TimeZone(identifier: "UTC")!, db: db)
        }
        let expectedTokens: Int64 = 8193 * 17 + 1
        #expect(query.rows.first?.totalTokens == expectedTokens)
        // 另一时区可独立重建，不能清理 UTC 的断点或中间结果。
        _ = try fixture.store.rebuildStatistics(timezone: "Asia/Shanghai")
        #expect(try fixture.lastID() == 8192)
        #expect(try fixture.stagedRecords() == 8192)
        try fixture.store.pool.write { db in
            try db.execute(sql: """
                DROP TRIGGER interrupt_statistics;
                CREATE TRIGGER reject_repeated_batch BEFORE INSERT ON app_metadata
                WHEN NEW.key = 'statistics_rebuild_checkpoint:\(fixture.timezone)' AND json_extract(NEW.value, '$.lastID') <= 8192
                BEGIN SELECT RAISE(ABORT, 'already committed batch repeated'); END;
                """)
        }
        let reopened = try UsageStore(databaseURL: fixture.store.databaseURL)
        let report = try reopened.rebuildStatistics(timezone: "UTC")
        #expect(try report.rebuilt && report.rows == fixture.cache().count)
        try fixture.expectMatchesFacts()
        #expect(try fixture.lastID() == nil)
        #expect(try fixture.stagedRecords() == 0)
    }

    @Test func checkpointWriteFailureRollsBackItsIntermediateAggregates() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let before = try fixture.cache()
        try fixture.store.pool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_checkpoint BEFORE INSERT ON app_metadata
                WHEN NEW.key LIKE 'statistics_rebuild_checkpoint:%'
                BEGIN SELECT RAISE(ABORT, 'checkpoint fixture failure'); END;
                """)
        }
        #expect(throws: (any Error).self) { try fixture.store.rebuildStatistics(timezone: "UTC") }
        #expect(try fixture.lastID() == nil)
        #expect(try fixture.stagedRecords() == 0)
        #expect(try fixture.cache() == before)
        try fixture.store.pool.write { try $0.execute(sql: "DROP TRIGGER reject_checkpoint") }
        _ = try fixture.store.rebuildStatistics(timezone: "UTC")
        try fixture.expectMatchesFacts()
    }

    @Test func failedPublicationKeepsCompleteProgressAndOldCache() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let before = try fixture.cache()
        try fixture.store.pool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_publication BEFORE INSERT ON statistics
                BEGIN SELECT RAISE(ABORT, 'publication fixture failure'); END;
                """)
        }
        #expect(throws: (any Error).self) { try fixture.store.rebuildStatistics(timezone: "UTC") }
        #expect(try fixture.lastID() == 8193)
        #expect(try fixture.stagedRecords() == 8193)
        #expect(try fixture.cache() == before)
        try fixture.store.pool.write { db in
            #expect(try !UsageStore.statisticsAreCurrent(db, timezone: fixture.timezone))
            try db.execute(sql: """
                DROP TRIGGER reject_publication;
                CREATE TRIGGER reject_rescan BEFORE INSERT ON statistics_rebuild
                BEGIN SELECT RAISE(ABORT, 'completed aggregates rescanned'); END;
                """)
        }
        _ = try UsageStore(databaseURL: fixture.store.databaseURL).rebuildStatistics(timezone: "UTC")
        try fixture.expectMatchesFacts()
        #expect(try fixture.lastID() == nil)
    }

    @Test(arguments: ["facts", "project", "version", "corrupt"])
    func invalidatedProgressRebuildsEveryBatch(change: String) throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try fixture.interruptAfterFirstBatch()
        try fixture.store.pool.write { db in
            try db.execute(sql: "DROP TRIGGER interrupt_statistics")
            switch change {
            case "facts": try db.execute(sql: "UPDATE usage SET total_tokens = total_tokens + 1 WHERE id = 1")
            case "project": try db.execute(sql: "UPDATE threads SET project_name = '新项目' WHERE thread_id = 't1'")
            case "version":
                try db.execute(sql: "UPDATE app_metadata SET value = json_set(value, '$.version', 0) WHERE key LIKE 'statistics_rebuild_checkpoint:%'")
            default:
                try db.execute(sql: "UPDATE app_metadata SET value = 'invalid JSON' WHERE key LIKE 'statistics_rebuild_checkpoint:%'")
            }
            // 损坏／旧版断点也必须丢弃暂存数据，不能碰巧合并出正确结果。
            try db.execute(sql: "UPDATE statistics_rebuild SET total_tokens = 999999")
        }
        _ = try fixture.store.rebuildStatistics(timezone: "UTC")
        try fixture.expectMatchesFacts()
        #expect(try fixture.lastID() == nil)
    }

    @Test func integerOverflowAcrossBatchesCannotPublishFloatingPointAmounts() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let before = try fixture.cache()
        try fixture.store.pool.write { db in
            try db.execute(sql: "UPDATE usage SET input_amount = NULL, output_amount = NULL, amount = NULL")
            try db.execute(sql: "UPDATE usage SET input_amount = ?, amount = ? WHERE id = 1", arguments: [Int64.max, Int64.max])
            try db.execute(sql: "UPDATE usage SET input_amount = 1, amount = 1 WHERE id = 8193")
        }
        #expect(throws: (any Error).self) { try fixture.store.rebuildStatistics(timezone: "UTC") }
        #expect(try fixture.lastID() == 8193)
        #expect(try fixture.cache() == before)
    }

    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store: UsageStore
        let timezone = TimeZone(identifier: "UTC")!.identifier

        init() throws {
            store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
            try store.pool.write { db in
                try db.execute(sql: """
                    INSERT INTO threads(thread_id, project_name) VALUES ('t1', 'unknown'), ('t2', NULL);
                    WITH RECURSIVE numbers(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM numbers WHERE n < 8193)
                    INSERT INTO usage(source_line,id, rollout_id, account_id, thread_id, occurred_at, usage_date, model,
                        total_tokens, input_tokens, output_tokens, cache_read_tokens, reasoning_tokens,
                        input_amount, output_amount, amount, source, evidence_json)
                    SELECT 1,n, 'fixture-' || n, CASE WHEN n % 2 = 0 THEN 'all' END,
                        CASE n % 3 WHEN 0 THEN 't1' WHEN 1 THEN 't2' END,
                        CASE WHEN n % 5 != 0 THEN 1772956800 + n % 10 * 60 END, '2026-03-08',
                        CASE WHEN n % 2 = 0 THEN 'model' END,
                        17, CASE WHEN n % 3 != 0 THEN 11 END, 6, 2, 1,
                        CASE WHEN n % 3 != 0 THEN 2 END, CASE WHEN n % 3 != 1 THEN 3 END,
                        CASE WHEN n % 3 = 2 THEN 5 END, 'local', '{"fixture":true}' FROM numbers;
                    """)
            }
            _ = try store.rebuildStatistics(timezone: "UTC")
            try store.pool.write { try $0.execute(sql: "UPDATE usage SET total_tokens = total_tokens + 1 WHERE id = 8193") }
        }

        func interruptAfterFirstBatch() throws {
            try store.pool.write { db in
                try db.execute(sql: """
                    CREATE TRIGGER interrupt_statistics BEFORE INSERT ON app_metadata
                    WHEN NEW.key = 'statistics_rebuild_checkpoint:\(timezone)' AND json_extract(NEW.value, '$.lastID') > 8192
                    BEGIN SELECT RAISE(ABORT, 'second batch fixture failure'); END;
                    """)
            }
            #expect(throws: (any Error).self) { try store.rebuildStatistics(timezone: "UTC") }
            #expect(try lastID() == 8192)
        }

        func lastID() throws -> Int64? {
            try store.pool.read { try Int64.fetchOne($0, sql: "SELECT json_extract(value, '$.lastID') FROM app_metadata WHERE key = ?",
                                                     arguments: ["statistics_rebuild_checkpoint:\(timezone)"]) }
        }

        func stagedRecords() throws -> Int {
            try store.pool.read { try Int.fetchOne($0, sql: "SELECT SUM(record_count) FROM statistics_rebuild WHERE timezone = ? AND account_key = 'all' AND dimension = 'all'",
                                                   arguments: [timezone]) ?? 0 }
        }

        func cache() throws -> [Row] {
            try store.pool.read { try Row.fetchAll($0, sql: "SELECT \(StatisticsSQL.columns) FROM statistics WHERE timezone = ? ORDER BY \(StatisticsSQL.groupColumns)", arguments: [timezone]) }
        }

        func expectMatchesFacts() throws {
            let expected = try store.pool.write { db in
                StatisticsSQL.prepare(db, timezone: TimeZone(identifier: "UTC")!)
                try db.execute(sql: "CREATE TEMP TABLE expected_statistics AS \(StatisticsSQL.aggregate)", arguments: ["timezone": timezone])
                let rows = try Row.fetchAll(db, sql: "SELECT * FROM expected_statistics ORDER BY \(StatisticsSQL.groupColumns)")
                try db.execute(sql: "DROP TABLE expected_statistics")
                return rows.map { Array($0.databaseValues) }
            }
            #expect(try cache().map { Array($0.databaseValues) } == expected)
        }

        func clean() { try? FileManager.default.removeItem(at: root) }
    }
}
