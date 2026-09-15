import Foundation
import GRDB
import Testing
@testable import TokenTickCore

struct QueryPerformanceTests {
    @Test func focusedAggregationMatchesCompleteCache() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        try store.pool.write { db in
            try db.execute(sql: """
                INSERT INTO threads(thread_id,title,project_name) VALUES ('a','任务 A','项目'),('b','任务 B',NULL);
                INSERT INTO usage(source_line,rollout_id,thread_id,account_id,usage_date,total_tokens,
                    input_tokens,input_amount,model,source,pricing_source) VALUES
                    (1,'1','a','account','2026-09-01',100,100,30,'model','local','{}'),
                    (1,'2','b',NULL,'2026-09-02',200,200,NULL,NULL,'local','{}'),
                    (1,'3',NULL,'account','2026-09-01',300,NULL,NULL,'model','local','{}'),
                    (1,'4','a','account','2026-09-02',400,400,0,'model','api','{}'),
                    (1,'5',NULL,'account','2026-09-02',900,NULL,NULL,NULL,'api','{}');
                """)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for zone in ["UTC", "Asia/Shanghai"] {
            _ = try store.rebuildStatistics(timezone: zone)
            for grouping in UsageGrouping.allCases {
                for account in [UsageAccountScope.all, .unknown, .account("account"), .account("missing")] {
                    for sort in UsageSort.allCases {
                        for offset in [0, 1, 5] {
                            let query = UsageQuery(grouping: grouping, timezone: zone, account: account,
                                                   limit: 1, offset: offset, sort: sort)
                            let cached = try store.usageReport(query)
                            let focused = try store.pool.read { db in
                                try UsageStore.readUsageReport(query, timezone: TimeZone(identifier: zone)!, db: db,
                                                               dateExpression: StatisticsSQL.dayExpression)
                            }
                            #expect(try encoder.encode(cached) == encoder.encode(focused))
                        }
                    }
                }
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TOKENTICK_BENCHMARK"] == "1"))
    func representativeQueries() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try store.pool.write { db in
            try db.execute(sql: """
                WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<1000)
                INSERT INTO threads(thread_id,title,project_name)
                SELECT 't'||x, '任务 '||x, '项目 '||(x%20) FROM n;
                WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<30000)
                INSERT INTO usage(source_line,rollout_id,thread_id,account_id,occurred_at,total_tokens,
                    input_tokens,input_amount,model,source,pricing_source)
                SELECT 1,'r'||x,'t'||(x%1000+1),CASE WHEN x%3=0 THEN NULL ELSE 'a' END,
                    ?-x*120,100,100,300,'m'||(x%5),'local','{}' FROM n;
                """, arguments: [now.timeIntervalSince1970])
        }
        _ = try store.rebuildStatistics(timezone: "UTC")
        for name in ["overview-week", "overview-month", "overview-all", "filtered-threads", "cached-days", "filter-options", "records", "status"] {
            var elapsed: [Double] = []
            for iteration in 0..<4 {
                let start = ContinuousClock.now
                switch name {
                case "overview-week", "overview-month", "overview-all":
                    let period: OverviewPeriod = name == "overview-week" ? .week : name == "overview-month" ? .month : .all
                    let report = try store.overviewReport(period: period, now: now, timezone: "UTC")
                    #expect(report.total?.totalTokens == report.models.reduce(0) { $0 + $1.totalTokens })
                    #expect(report.conversations.count == 10)
                case "filtered-threads":
                    var query = OverviewPeriod.month.query(now: now, timezone: "UTC")
                    query.grouping = .thread
                    let report = try store.usageReport(query)
                    #expect(report.totalGroups == 1000)
                case "cached-days": _ = try store.usageReport(UsageQuery(timezone: "UTC"))
                case "filter-options": _ = try store.usageFilterOptions(OverviewPeriod.month.query(now: now, timezone: "UTC"))
                case "records": _ = try store.usageRecords(OverviewPeriod.month.query(now: now, timezone: "UTC"))
                default: _ = try store.status()
                }
                let duration = start.duration(to: .now).components
                if iteration > 0 { elapsed.append(Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15) }
            }
            print("BENCHMARK \(name) ms=\(elapsed.sorted())")
        }
    }
}
