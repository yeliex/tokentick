import Foundation
import GRDB
import Testing
@testable import TokenTickCore

struct RollingUsageTests {
    @Test func exactRangeUsesFactsPreservesAccountAndDrillDownAcrossTimezones() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        let start = try #require(DateParsing.parseTimestamp("2026-09-09T12:30:00Z")).timeIntervalSince1970
        try store.pool.write { db in
            try db.execute(sql: """
                INSERT INTO threads(thread_id, title, project_name) VALUES ('a','任务 A','项目 A');
                INSERT INTO usage(source_line,rollout_id,thread_id,account_id,occurred_at,usage_date,total_tokens,model,source,evidence_json) VALUES
                  (1,'before','a','account-a',?,'2026-09-09',1,'m','local','{}'),
                  (1,'start','a','account-a',?,'2026-09-09',20,'m','local','{}'),
                  (1,'inside','a',NULL,?,'2026-09-10',40,'m','local','{}'),
                  (1,'end','a','account-a',?,'2026-09-10',80,'m','local','{}'),
                  (1,'date-only','a',NULL,NULL,'2026-09-09',160,NULL,'local','{}');
                UPDATE usage SET input_amount = total_tokens * 2 WHERE rollout_id != 'date-only';
                """, arguments: [start - 1, start, start + 86399, start + 86400])
        }
        // 即使日缓存已存在，滚动边界也不能包含首尾自然日的额外用量。
        _ = try store.rebuildStatistics(timezone: "UTC")
        for zone in ["UTC", "Asia/Shanghai", "America/Los_Angeles"] {
            var query = UsageQuery(grouping: .total, timezone: zone)
            query.filters.occurredFrom = start
            query.filters.occurredBefore = start + 86400
            for grouping in UsageGrouping.allCases {
                query.grouping = grouping
                let report = try store.usageReport(query)
                #expect(report.rows.reduce(0) { $0 + $1.totalTokens } == 60)
                #expect(report.rows.reduce(0) { $0 + ($1.knownAmountNanoUSD ?? 0) } == 120)
                for row in report.rows {
                    let records = try store.usageRecords(query.focused(on: grouping, value: row.group)).rows
                    #expect(records.reduce(0) { $0 + $1.totalTokens } == row.totalTokens)
                }
            }
            query.grouping = .total
            query.account = .account("account-a")
            #expect(try store.usageReport(query).rows.first?.totalTokens == 20)
            #expect(try store.usageRecords(query).rows.map(\.totalTokens) == [20])
            query.account = .unknown
            #expect(try store.usageReport(query).rows.first?.totalTokens == 40)
        }
        #expect(try store.usageReport(UsageQuery(grouping: .total)).rows.first?.totalTokens == 301)
    }

    @Test func rejectsNonfiniteAndReversedTimeBoundaries() throws {
        for (from, before) in [(Double.nan, 100.0), (0, Double.infinity), (100, 100), (101, 100)] {
            var query = UsageQuery()
            query.filters.occurredFrom = from
            query.filters.occurredBefore = before
            #expect(throws: UsageQueryError.self) { try query.validate() }
        }
    }
}
