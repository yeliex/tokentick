import Foundation
import GRDB
import Testing
@testable import TokenTickCore

struct StatisticsTests {
    @Test func everyDimensionMatchesFactsAndKeepsPartialAmountsAndUnknownKeys() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let total = try #require(fixture.store.usageReport(UsageQuery(grouping: .total, timezone: "UTC")).rows.first)
        #expect(total.totalTokens == 200 && total.records == 4)
        #expect(total.inputTokens == 115 && total.outputTokens == 15)
        #expect(total.knownAmountNanoUSD == 17 && total.completeAmountNanoUSD == 10)
        #expect(total.inputAmountNanoUSD == 1 && total.outputAmountNanoUSD == 9)
        #expect(total.unpricedTokens == 90 && total.unpricedRecords == 3 && total.unattributedTokens == 70)
        for grouping in UsageGrouping.allCases {
            let report = try fixture.store.usageReport(UsageQuery(grouping: grouping, timezone: "UTC"))
            #expect(report.rows.reduce(0) { $0 + $1.totalTokens } == total.totalTokens)
            #expect(report.rows.reduce(0) { $0 + ($1.knownAmountNanoUSD ?? 0) } == 17)
            #expect(report.rows.reduce(0) { $0 + $1.unpricedTokens } == 90)
        }
        let projects = try fixture.store.usageReport(UsageQuery(grouping: .project, timezone: "UTC")).rows
        #expect(projects.first(where: { $0.group == "unknown" })?.totalTokens == 110)
        #expect(projects.first(where: { $0.group == nil })?.totalTokens == 90)
        let model = try #require(fixture.store.usageReport(UsageQuery(grouping: .model, timezone: "UTC")).rows.first(where: { $0.group == nil }))
        #expect(model.knownAmountNanoUSD == nil)
        #expect(model.inputAmountNanoUSD == 0)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(model)) as? [String: Any]
        #expect(json?["knownAmountNanoUSD"] is NSNull && json?["completeAmountNanoUSD"] is NSNull)
        #expect(try fixture.store.usageReport(UsageQuery(grouping: .total, timezone: "UTC", account: .unknown)).rows.first?.totalTokens == 50)
        #expect(try fixture.store.usageReport(UsageQuery(grouping: .total, timezone: "UTC", account: .account("all"))).rows.first?.totalTokens == 110)
        #expect(try fixture.store.usageReport(UsageQuery(grouping: .total, timezone: "UTC", account: .account("unknown"))).rows.first?.totalTokens == 40)
    }

    @Test func timezoneDSTDateOnlyRecordsInclusiveRangeAndStablePagination() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let report = try fixture.store.usageReport(UsageQuery(timezone: "America/Los_Angeles"))
        #expect(report.rows.map(\.group) == ["2026-03-08", "2026-03-07", nil])
        #expect(report.rows.map(\.totalTokens) == [50, 110, 40])
        #expect(report.unknownDateTokens == 40)
        let range = try fixture.store.usageReport(UsageQuery(timezone: "America/Los_Angeles", fromDate: "2026-03-08", throughDate: "2026-03-08"))
        #expect(range.rows.count == 1 && range.rows.first?.totalTokens == 50)
        #expect(range.unknownDateTokens == 40)
        let page = try fixture.store.usageReport(UsageQuery(timezone: "America/Los_Angeles", limit: 1, offset: 1))
        #expect(page.rows == [report.rows[1]])
        #expect(try fixture.store.usageReport(UsageQuery(timezone: "America/Los_Angeles", fromDate: "2026-04-01")).rows.isEmpty)
        try fixture.store.setStatisticsTimezone("America/Los_Angeles")
        #expect(try fixture.store.usageReport().rows == report.rows)
        _ = try fixture.store.usageReport(UsageQuery(timezone: "UTC"))
        #expect(try fixture.store.statisticsTimezone() == "America/Los_Angeles")
        let reopened = try UsageStore(databaseURL: fixture.store.databaseURL)
        #expect(try reopened.usageReport().rows == report.rows)
    }

    @Test func committedFactChangesAndProjectRenamesInvalidateEveryTimezoneButTitlesDoNot() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let utc = try #require(TimeZone(identifier: "UTC"))
        _ = try fixture.store.rebuildStatistics(timezone: "UTC")
        _ = try fixture.store.rebuildStatistics(timezone: "Asia/Shanghai")
        #expect(try !fixture.store.rebuildStatistics(timezone: utc, onlyIfNeeded: true).rebuilt)
        try fixture.store.pool.write { db in
            try db.execute(sql: "UPDATE threads SET title = '新标题' WHERE thread_id = 't1'")
            #expect(try UsageStore.statisticsAreCurrent(db, timezone: utc.identifier))
            try db.execute(sql: "UPDATE threads SET project_name = '新项目' WHERE thread_id = 't1'")
            #expect(try !UsageStore.statisticsAreCurrent(db, timezone: utc.identifier))
            #expect(try !UsageStore.statisticsAreCurrent(db, timezone: "Asia/Shanghai"))
        }
        let projects = try fixture.store.usageReport(UsageQuery(grouping: .project, timezone: "UTC")).rows
        #expect(!projects.contains(where: { $0.group == "unknown" }))
        #expect(projects.first(where: { $0.group == "新项目" })?.totalTokens == 110)
        try fixture.store.pool.write { db in
            try db.execute(sql: "UPDATE usage SET input_amount = 11, amount = 20 WHERE rollout_id = 'a'")
        }
        #expect(try fixture.store.usageReport(UsageQuery(grouping: .total, timezone: "UTC")).rows.first?.knownAmountNanoUSD == 27)
        try fixture.store.pool.write { db in try db.execute(sql: "DELETE FROM usage WHERE rollout_id = 'd'") }
        #expect(try fixture.store.usageReport(UsageQuery(grouping: .total, timezone: "UTC")).rows.first?.totalTokens == 160)
    }

    @Test(arguments: [false, true]) func failedRebuildRollsBackCacheAndOverflowCannotBecomeFloatingPointMoney(onlyIfNeeded: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        _ = try fixture.store.rebuildStatistics(timezone: "UTC")
        let before = try fixture.store.pool.read { db in try Row.fetchAll(db, sql: "SELECT * FROM statistics ORDER BY account_key, date, dimension, dimension_value") }
        try fixture.store.pool.write { db in
            try db.execute(sql: "UPDATE usage SET input_amount = ?, output_amount = 1, amount = NULL WHERE rollout_id = 'a'", arguments: [Int64.max])
        }
        #expect(throws: (any Error).self) { try fixture.store.rebuildStatistics(timezone: "UTC", onlyIfNeeded: onlyIfNeeded) }
        let after = try fixture.store.pool.read { db in try Row.fetchAll(db, sql: "SELECT * FROM statistics ORDER BY account_key, date, dimension, dimension_value") }
        #expect(before == after)
        #expect(try fixture.store.pool.read { try !UsageStore.statisticsAreCurrent($0, timezone: TimeZone(identifier: "UTC")!.identifier) })
        #expect(throws: (any Error).self) { try fixture.store.usageReport(UsageQuery(timezone: "UTC")) }
    }

    @Test func incrementalRebuildPreservesUnchangedDatesAndMatchesFullRebuild() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try fixture.store.pool.write { db in
            try db.execute(sql: """
                INSERT INTO usage(source_line,rollout_id,occurred_at,usage_date,total_tokens,source)
                VALUES (1,'old',1735689600,'2025-01-01',50,'local')
                """)
        }
        _ = try fixture.store.rebuildStatistics(timezone: "UTC")
        try fixture.store.pool.write { db in
            try db.execute(sql: """
                CREATE TRIGGER preserve_old_statistics BEFORE DELETE ON statistics
                WHEN OLD.date = '2025-01-01'
                BEGIN SELECT RAISE(ABORT, 'Unchanged dates must not be rebuilt'); END;
                UPDATE usage SET total_tokens = 120 WHERE rollout_id = 'a';
                """)
        }
        #expect(try fixture.store.rebuildStatistics(timezone: "UTC", onlyIfNeeded: true).rebuilt)
        let incremental = try fixture.store.pool.read {
            try Row.fetchAll($0, sql: "SELECT * FROM statistics ORDER BY timezone,account_key,date,dimension,dimension_value")
        }
        try fixture.store.pool.write { try $0.execute(sql: "DROP TRIGGER preserve_old_statistics") }
        _ = try fixture.store.rebuildStatistics(timezone: "UTC")
        let full = try fixture.store.pool.read {
            try Row.fetchAll($0, sql: "SELECT * FROM statistics ORDER BY timezone,account_key,date,dimension,dimension_value")
        }
        #expect(incremental == full)
    }

    @Test func badFiltersAreRejectedBeforeChangingCache() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        for query in [UsageQuery(timezone: "invalid/timezone"), UsageQuery(fromDate: "2026-02-31"),
                      UsageQuery(fromDate: "2026-09-02", throughDate: "2026-09-01"), UsageQuery(limit: 0), UsageQuery(offset: -1)] {
            #expect(throws: UsageQueryError.self) { try fixture.store.usageReport(query) }
        }
        #expect(try fixture.store.tableCounts()["statistics"] == 0)
    }

    @Test func anotherConnectionCommitUsesFactsWhenCacheBecomesStaleBeforeReading() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let timezone = try #require(TimeZone(identifier: "UTC"))
        _ = try fixture.store.rebuildStatistics(timezone: "UTC")
        let writer = try UsageStore(databaseURL: fixture.store.databaseURL)
        try writer.pool.write { db in
            try db.execute(sql: "INSERT INTO usage(source_line,rollout_id, usage_date, total_tokens, source, pricing_source) VALUES (1,'new', '2026-03-08', 100, 'local', '{}')")
        }
        let report = try fixture.store.pool.read { db in
            try UsageStore.readUsageReport(UsageQuery(grouping: .total, timezone: "UTC"), timezone: timezone, db: db)
        }
        #expect(report.rows.first?.totalTokens == 300)
        #expect(try fixture.store.pool.read { db in
            try Int64.fetchOne(db, sql: "SELECT SUM(total_tokens) FROM statistics WHERE account_key = 'all' AND dimension = 'all'")
        } == 200)
        let cached = try fixture.store.usageReport(UsageQuery(grouping: .total, timezone: "UTC"))
        #expect(cached.rows == report.rows)
    }

    @Test func rolledBackUsageDoesNotInvalidateCommittedStatistics() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let before = try fixture.store.rebuildStatistics(timezone: "UTC")
        enum Failure: Error { case rollback }
        #expect(throws: Failure.self) {
            try fixture.store.pool.write { db in
                try db.execute(sql: "DELETE FROM usage")
                throw Failure.rollback
            }
        }
        let after = try fixture.store.rebuildStatistics(timezone: #require(TimeZone(identifier: "UTC")), onlyIfNeeded: true)
        #expect(!after.rebuilt && before.revision == after.revision)
        #expect(try fixture.store.usageReport(UsageQuery(grouping: .total, timezone: "UTC")).rows.first?.totalTokens == 200)
    }

    @Test func queryDuringScanReadsCommittedFactsWithoutWaitingForTheWholeScanLock() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        _ = try fixture.store.rebuildStatistics(timezone: "UTC")
        let lock = FileWriteLock(url: fixture.store.databaseURL.appendingPathExtension("write.lock"))
        try lock.withLock {
            try fixture.store.pool.write { db in try db.execute(sql: "DELETE FROM usage WHERE rollout_id = 'd'") }
            let report = try fixture.store.usageReport(UsageQuery(grouping: .total, timezone: "UTC"))
            #expect(report.rows.first?.totalTokens == 160)
        }
        #expect(try fixture.store.rebuildStatistics(timezone: #require(TimeZone(identifier: "UTC")), onlyIfNeeded: true).rebuilt)
    }

    private struct Fixture {
        let root: URL
        let store: UsageStore
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
            try store.pool.write { db in
                try db.execute(sql: "INSERT INTO threads(thread_id, title, project_name) VALUES ('t1', '标题', 'unknown'), ('t2', '标题', NULL)")
                let dates = ["2026-03-08T07:59:00Z", "2026-03-08T08:01:00Z", "2026-03-09T06:59:00Z"]
                let times = try dates.map { try #require(DateParsing.parseTimestamp($0)).timeIntervalSince1970 }
                try db.execute(sql: """
                    INSERT INTO usage(source_line,rollout_id, account_id, thread_id, occurred_at, usage_date, model,
                        input_tokens, output_tokens, cache_read_tokens, total_tokens, input_amount, output_amount,
                        cache_read_amount, cache_write_amount, amount, source, pricing_source) VALUES
                    (1,'a', 'all', 't1', ?, '2026-03-08', 'model', 100, 10, 20, 110, 1, 2, 3, 4, 10, 'local', '{}'),
                    (1,'b', NULL, 't2', ?, '2026-03-08', 'value:', 15, 5, 0, 20, NULL, 7, 0, 0, NULL, 'local', '{}'),
                    (1,'c', NULL, NULL, ?, '2026-03-09', NULL, NULL, NULL, NULL, 30, 0, NULL, NULL, NULL, NULL, 'local', '{}'),
                    (1,'d', 'unknown', NULL, NULL, '2026-03-08', NULL, NULL, NULL, NULL, 40, NULL, NULL, NULL, NULL, NULL, 'local', '{}')
                    """, arguments: StatementArguments(times))
            }
        }
        func clean() { try? FileManager.default.removeItem(at: root) }
    }
}
