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
        #expect(try store.tableCounts().count == 6)
        try store.pool.write { db in
            try db.execute(sql: "INSERT INTO usage (source_line,rollout_id, total_tokens, usage_date, source, pricing_source) VALUES (1,'api-day', 100, '2026-09-09', 'api', '{}')")
        }
        let reopened = try UsageStore(databaseURL: url)
        #expect(try reopened.tableCounts()["usage"] == 1)
        let row = try reopened.pool.read { db in try Row.fetchOne(db, sql: "SELECT amount, model, tier FROM usage") }
        #expect(row?["amount"] as Int64? == nil)
        #expect(row?["model"] as String? == nil)
        #expect(row?["tier"] as String? == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("Backups").path))
    }



    @Test func developmentSchemaRebuildDropsOldFactsAndRedundantTables() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("usage.sqlite")
        let old = try DatabaseQueue(path: url.path)
        try old.write { try $0.execute(sql: """
            CREATE TABLE grdb_migrations(identifier TEXT PRIMARY KEY);
            INSERT INTO grdb_migrations VALUES ('old-development-schema');
            CREATE TABLE usage(evidence_json TEXT);
            INSERT INTO usage VALUES ('discard');
            CREATE TABLE turn_usage(id TEXT);
            CREATE TABLE statistics_rebuild(id TEXT);
            CREATE TABLE weekly_limit_observations(id TEXT);
            """) }
        try old.close()
        let store = try UsageStore(databaseURL: url)
        #expect(try store.tableCounts()["usage"] == 0)
        try store.pool.read { db throws -> Void in
            for name in ["turn_usage","statistics_rebuild","weekly_limit_observations"] {
                #expect(try !db.tableExists(name))
            }
            for name in ["usage","weekly_limit_cycles"] {
                #expect(try !db.columns(in: name).contains { $0.name.hasSuffix("_json") })
            }
        }
    }

    @Test func globalKeepsLocalUnknownAccountsAndAllAggregatesExcludeUnassignedAPI() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        try store.pool.write { db in
            try db.execute(sql: """
                INSERT INTO threads(thread_id,title,project_name) VALUES ('t','任务','项目');
                INSERT INTO usage(source_line,rollout_id,account_id,thread_id,usage_date,total_tokens,source,pricing_source) VALUES
                (1,'local-known','a','t','2026-09-09',10,'local','{}'),
                (1,'local-unknown',NULL,'t','2026-09-09',20,'local','{}'),
                (1,'api-unassigned','a',NULL,'2026-09-09',100,'api','{}'),
                (1,'api-assigned','a','t','2026-09-09',5,'api','{}');
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



}
