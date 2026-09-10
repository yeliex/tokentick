import Foundation
import GRDB
import Testing
@testable import TokenTickCore

struct UsageStoreTests {
    @Test func newStoreCreatesExpectedTablesAndKeepsUnknownValues() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("usage.sqlite")
        let store = try UsageStore(databaseURL: url)
        #expect(try store.tableCounts().count == 7)
        try store.pool.write { db in
            try db.execute(sql: "INSERT INTO usage (dedup_key, total_tokens, usage_date, source, evidence_json) VALUES ('api-day', 100, '2026-09-09', 'api', '{}')")
        }
        let reopened = try UsageStore(databaseURL: url)
        #expect(try reopened.tableCounts()["usage"] == 1)
        let row = try reopened.pool.read { db in try Row.fetchOne(db, sql: "SELECT amount, model, is_fast FROM usage") }
        #expect(row?["amount"] as Int64? == nil)
        #expect(row?["model"] as String? == nil)
        #expect(row?["is_fast"] as Bool? == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("Backups").path))
    }

    @Test func weeklyMigrationKeepsWeekEvidenceAndBacksUpOldFiveHourHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("usage.sqlite")
        let old = try DatabaseQueue(path: url.path)
        try StoreSchema.migrator.migrate(old, upTo: "v4.statistics-recovery")
        try old.write { db in
            try db.execute(sql: """
                INSERT INTO limit_windows(account_id,limit_id,window_kind,starts_at,resets_at,window_duration_mins,used_percent,last_observed_at,source_json) VALUES
                ('a','codex','primary',0,18000,300,10,100,'{}'),
                ('a','codex','secondary',0,604800,10080,90,100,'{}');
                INSERT INTO api_daily_usage VALUES ('a','2026-09-09',123,100);
                INSERT INTO app_metadata VALUES ('api_limits:a','{}'), ('statistics_cache_revision:UTC','0');
                """)
        }
        try old.close()
        let store = try UsageStore(databaseURL: url)
        #expect(try store.tableCounts()["weekly_limit_observations"] == 1)
        #expect(try store.apiDailyUsage().first?.tokens == 123)
        try store.pool.read { db throws -> Void in
            #expect(try !db.tableExists("limit_windows"))
            #expect(try String.fetchOne(db, sql: "SELECT value FROM app_metadata WHERE key='api_limits:a'") == nil)
            #expect(try !UsageStore.statisticsAreCurrent(db, timezone: "UTC"))
        }
        let backups = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Backups"), includingPropertiesForKeys: nil)
        let backup = try DatabaseQueue(path: #require(backups.first(where: { $0.pathExtension == "sqlite" })).path)
        #expect(try backup.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM limit_windows") } == 2)
    }

    @Test func globalKeepsLocalUnknownAccountsAndAllAggregatesExcludeUnassignedAPI() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        try store.pool.write { db in
            try db.execute(sql: """
                INSERT INTO threads(thread_id,title,project_name) VALUES ('t','任务','项目');
                INSERT INTO usage(dedup_key,account_id,thread_id,usage_date,total_tokens,source,evidence_json) VALUES
                ('local-known','a','t','2026-09-09',10,'local','{}'),
                ('local-unknown',NULL,'t','2026-09-09',20,'local','{}'),
                ('api-unassigned','a',NULL,'2026-09-09',100,'api','{}'),
                ('api-assigned','a','t','2026-09-09',5,'api','{}');
                """)
        }
        for cached in [false, true] {
            if cached { _ = try store.rebuildStatistics(timezone: "UTC") }
            for grouping in UsageGrouping.allCases {
                #expect(try store.usageReport(UsageQuery(grouping: grouping, timezone: "UTC")).rows.reduce(0) { $0 + $1.totalTokens } == 35)
            }
            #expect(try store.usageReport(UsageQuery(grouping: .total, timezone: "UTC", account: .account("a"))).rows.first?.totalTokens == 15)
            #expect(try store.usageReport(UsageQuery(grouping: .total, timezone: "UTC", account: .unknown)).rows.first?.totalTokens == 20)
        }
        #expect(try store.usageRecords().rows.count == 4)
    }

    @Test func unknownFutureMigrationRefusesToOpen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("usage.sqlite")
        let store = try UsageStore(databaseURL: url)
        try store.pool.write { db in
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v999.future')")
        }
        #expect(throws: UsageStore.StoreError.newerSchema) { try UsageStore(databaseURL: url) }
        #expect(UsageStore.StoreError.newerSchema.localizedDescription.contains("请更新 TokenTick"))
        #expect(try store.pool.read { db in try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations") }.contains("v999.future"))
    }

    @Test func migrationBacksUpExistingUnmigratedDatabase() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("usage.sqlite")
        let original = try DatabaseQueue(path: url.path)
        try original.write { db in
            try db.execute(sql: "CREATE TABLE existing_data (value TEXT); INSERT INTO existing_data VALUES ('keep')")
        }
        _ = try UsageStore(databaseURL: url)
        let backups = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("Backups"), includingPropertiesForKeys: nil)
        let backup = try #require(backups.first(where: { $0.pathExtension == "sqlite" }))
        var configuration = Configuration()
        configuration.readonly = true
        let restored = try DatabaseQueue(path: backup.path, configuration: configuration)
        #expect(try restored.read { db in try String.fetchOne(db, sql: "SELECT value FROM existing_data") } == "keep")
        #expect(try restored.read { db in try db.tableExists("usage") } == false)
    }
    @Test func restoredWALDatabaseWithoutSidecarsCanBeOpened() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try UsageStore(databaseURL: root.appendingPathComponent("original.sqlite"))
        try original.pool.write { db in
            try db.execute(sql: "INSERT INTO threads(thread_id, title) VALUES ('restored', '保留标题')")
        }
        let restoredURL = root.appendingPathComponent("restored.sqlite")
        let destination = try DatabaseQueue(path: restoredURL.path)
        try original.pool.backup(to: destination)
        try destination.close()
        // 独立备份只需要主文件；恢复不能依赖原始进程残留的 WAL/SHM。
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: restoredURL.path + suffix)
            if FileManager.default.fileExists(atPath: sidecar.path) { try FileManager.default.removeItem(at: sidecar) }
        }
        let restored = try UsageStore(databaseURL: restoredURL)
        let title = try restored.pool.read { try String.fetchOne($0, sql: "SELECT title FROM threads WHERE thread_id = 'restored'") }
        #expect(title == "保留标题")
    }

    @Test func statisticsRecoveryMigrationPreservesFactsCacheAndOtherCheckpoints() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("usage.sqlite")
        let old = try DatabaseQueue(path: url.path)
        try StoreSchema.migrator.migrate(old, upTo: "v3.statistics-cache")
        try old.write { db in
            try db.execute(sql: """
                INSERT INTO usage(dedup_key, usage_date, total_tokens, source, evidence_json)
                    VALUES ('fixture', '2026-09-10', 7, 'local', '{"keep":true}');
                INSERT INTO statistics(account_key, date, timezone, dimension, dimension_value,
                    total_tokens, unpriced_tokens, unattributed_tokens, record_count)
                    VALUES ('all', '2026-09-10', 'GMT', 'all', 'all', 7, 7, 7, 1);
                INSERT INTO app_metadata(key, value) VALUES ('reprice_checkpoint', '{"keep":true}');
                """)
        }
        let before = try old.read { db in
            try ["usage", "statistics", "app_metadata"].map { try Row.fetchAll(db, sql: "SELECT * FROM \($0) ORDER BY 1") }
        }
        try old.close()
        let current = try UsageStore(databaseURL: url)
        let after = try current.pool.read { db in
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM statistics_rebuild") == 0)
            return try ["usage", "statistics", "app_metadata"].map { try Row.fetchAll(db, sql: "SELECT * FROM \($0) ORDER BY 1") }
        }
        #expect(before[0] == after[0] && before[1] == after[1])
        #expect(try current.pool.read { try String.fetchOne($0, sql: "SELECT value FROM app_metadata WHERE key = 'reprice_checkpoint'") } == "{\"keep\":true}")
        #expect(try !current.status().cacheCurrent)
        let backups = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Backups"), includingPropertiesForKeys: nil)
        let backup = try DatabaseQueue(path: #require(backups.first(where: { $0.pathExtension == "sqlite" })).path)
        try backup.read { db in
            let hasStaging = try db.tableExists("statistics_rebuild")
            let saved = try ["usage", "statistics", "app_metadata"].map { try Row.fetchAll(db, sql: "SELECT * FROM \($0) ORDER BY 1") }
            #expect(!hasStaging && saved == before)
        }
    }

}
