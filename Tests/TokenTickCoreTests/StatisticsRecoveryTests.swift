import Foundation
import GRDB
import Testing
@testable import TokenTickCore

struct StatisticsRecoveryTests {
    @Test func incrementalRefreshKeepsUnchangedDaysAndMatchesFullRebuild() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        try store.pool.write { try $0.execute(sql: """
            INSERT INTO usage(rollout_id,source_line,usage_date,total_tokens,source) VALUES
                ('old',1,'2026-01-01',10,'local'),('recent',1,'2026-09-01',20,'local');
            """) }
        _ = try store.rebuildStatistics(timezone: "UTC")
        try store.pool.write { try $0.execute(sql: """
            UPDATE usage SET total_tokens=30 WHERE rollout_id='recent';
            CREATE TRIGGER protect_unchanged_day BEFORE DELETE ON statistics WHEN OLD.date='2026-01-01'
            BEGIN SELECT RAISE(ABORT,'unnecessary rebuild'); END;
            """) }
        #expect(try store.usageReport(UsageQuery(grouping: .total, timezone: "UTC")).rows.first?.totalTokens == 40)
        let incremental = try store.pool.read { try Row.fetchAll($0, sql: "SELECT * FROM statistics ORDER BY 1,2,3,4,5") }
        try store.pool.write { try $0.execute(sql: "DROP TRIGGER protect_unchanged_day") }
        _ = try store.rebuildStatistics(timezone: "UTC")
        #expect(try store.pool.read { try Row.fetchAll($0, sql: "SELECT * FROM statistics ORDER BY 1,2,3,4,5") } == incremental)
    }

    @Test func dateOnlyRecordsRefreshUnknownBucketOutsideUTC() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        _ = try store.rebuildStatistics(timezone: "Asia/Shanghai")
        try store.pool.write { try $0.execute(sql: """
            INSERT INTO usage(rollout_id,source_line,usage_date,total_tokens,source) VALUES ('date-only',1,'2026-09-01',20,'local');
            """) }
        let result = try store.usageReport(UsageQuery(grouping: .total, timezone: "Asia/Shanghai"))
        #expect(result.rows.first?.totalTokens == 20 && result.unknownDateTokens == 20)
    }

    @Test func failedRebuildRollsBackPublishedCacheAndRetryStartsClean() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        try store.pool.write { try $0.execute(sql: """
            INSERT INTO usage(rollout_id,source_line,usage_date,total_tokens,source) VALUES ('one',1,'2026-09-01',10,'local');
            """) }
        _ = try store.rebuildStatistics(timezone: "UTC")
        let before = try store.pool.read { try Row.fetchAll($0, sql: "SELECT * FROM statistics ORDER BY 1,2,3,4,5") }
        try store.pool.write { try $0.execute(sql: """
            INSERT INTO usage(rollout_id,source_line,usage_date,total_tokens,source) VALUES ('two',1,'2026-09-02',20,'local');
            CREATE TRIGGER fail_statistics BEFORE INSERT ON statistics BEGIN SELECT RAISE(ABORT,'fixture'); END;
            """) }
        #expect(throws: (any Error).self) { try store.rebuildStatistics(timezone: "UTC") }
        #expect(try store.pool.read { try Row.fetchAll($0, sql: "SELECT * FROM statistics ORDER BY 1,2,3,4,5") } == before)
        try store.pool.write { try $0.execute(sql: "DROP TRIGGER fail_statistics") }
        _ = try store.rebuildStatistics(timezone: "UTC")
        #expect(try store.usageReport(UsageQuery(grouping: .total, timezone: "UTC")).rows.first?.totalTokens == 30)
        #expect(try store.pool.read { try !$0.tableExists("statistics_rebuild") })
    }
}
