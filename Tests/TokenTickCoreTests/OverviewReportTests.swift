import Foundation
import GRDB
import Testing
@testable import TokenTickCore

struct OverviewReportTests {


    @Test func fastTraceOnlyAppliesWhenObservedTierIsAbsent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        try store.pool.write { db in
            try db.execute(sql: """
                INSERT INTO app_metadata(key,value) VALUES ('fast_trace:thread:turn','{}');
                INSERT INTO usage(source_line,rollout_id,thread_id,turn_id,total_tokens,tier,is_long_context,usage_date,source,pricing_source) VALUES
                    (1,'trace','thread','turn',100,NULL,0,'2026-09-01','local','{}'),
                    (1,'standard','thread','turn',200,'standard',0,'2026-09-01','local','{}'),
                    (1,'fast','thread','other',300,'fast',0,'2026-09-01','local','{}'),
                    (1,'default','thread','other',400,NULL,0,'2026-09-01','local','{}');
                """)
        }
        let report = try store.overviewReport(period: .all, now: Date(), timezone: "UTC")
        #expect(report.modes.first { $0.name == "快速" }?.tokens == 400)
        #expect(report.modes.first { $0.name == "普通" }?.tokens == 600)
    }

    @Test func nestedSharesPartitionRequestsAndRespectPeriodAndKnownAmounts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try store.pool.write { db in
            for (index, mode) in [(0, 0), (1, 0), (0, 1), (1, 1)].enumerated() {
                try db.execute(sql: """
                    INSERT INTO usage(source_line,rollout_id,occurred_at,total_tokens,input_tokens,input_amount,is_long_context,tier,reasoning_effort,source,pricing_source)
                    VALUES (1,?,?,100,100,10,?,?,'high','local',?)
                    """, arguments: [String(index), now.timeIntervalSince1970 - 1, mode.1, mode.0 == 1 ? "fast" : "standard",
                        "{\"pricingMode\":{\"isFast\":\(mode.0)},\"reasoningEffort\":\"high\"}"])
            }
            try db.execute(sql: """
                INSERT INTO usage(source_line,rollout_id,occurred_at,total_tokens,source,pricing_source) VALUES
                    (1,'unknown',?,50,'local','{}'), (1,'old',?,999,'local','{}'), (1,'api',?,999,'api','{}')
                """, arguments: [now.timeIntervalSince1970 - 1, now.timeIntervalSince1970 - 86401, now.timeIntervalSince1970 - 1])
        }
        let report = try store.overviewReport(period: .day, now: now, timezone: "UTC")
        #expect(Set(report.modes.map(\.name)) == ["普通", "快速", "长上下文", "快速＋长上下文", "未知"])
        #expect(report.modes.reduce(0) { $0 + $1.tokens } == report.total?.totalTokens)
        #expect(report.efforts.reduce(0) { $0 + $1.tokens } == 450)
        #expect(report.modes.reduce(0) { $0 + ($1.amount ?? 0) } == report.total?.knownAmountNanoUSD)
        #expect(report.efforts.first { $0.name == "high" }?.tokens == 400)
        #expect(report.efforts.first { $0.name == "未知" }?.amount == nil)
    }

    @Test func historyDateRangeUsesAllMatchingDaysBeforePagination() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        try store.pool.write { db in
            try db.execute(sql: """
                INSERT INTO usage(source_line,rollout_id,occurred_at,usage_date,total_tokens,model,source,pricing_source) VALUES
                    (1,'old',NULL,'2026-01-01',10,'a','local','{}'),
                    (1,'recent',NULL,'2026-09-14',20,'b','local','{}');
                """)
        }
        try store.updateThreadMappings([ThreadMapping(threadID: "old", title: nil, projectName: "旧项目"), ThreadMapping(threadID: "recent", title: nil, projectName: "Chat")])
        try store.pool.write { try $0.execute(sql: "UPDATE usage SET thread_id = rollout_id") }
        let choices = try store.usageFilterOptions(UsageQuery(timezone: "UTC", fromDate: "2026-09-01", throughDate: "2026-09-14"))
        #expect(choices.models == ["b"])
        #expect(choices.projects == ["Chat"])
        let report = try store.usageReport(UsageQuery(grouping: .day, timezone: "UTC", limit: 1))
        #expect(report.rows.count == 1 && report.hasMore)
        #expect(report.dataFromDate == "2026-01-01" && report.dataThroughDate == "2026-09-14")
        var filters = UsageFilters(); filters.model = .value("b")
        let filtered = try store.usageReport(UsageQuery(grouping: .total, timezone: "UTC", filters: filters))
        #expect(filtered.dataFromDate == "2026-09-14" && filtered.dataThroughDate == "2026-09-14")
        let unknown = try store.usageReport(UsageQuery(grouping: .total, timezone: "Asia/Shanghai"))
        #expect(unknown.dataFromDate == nil && unknown.dataThroughDate == nil)
        filters.model = .value("missing")
        let empty = try store.usageReport(UsageQuery(grouping: .total, timezone: "UTC", filters: filters))
        #expect(empty.dataFromDate == nil && empty.dataThroughDate == nil)
    }

    @Test func filterChoicesUseStoredValuesWithoutDuplicatesOrNulls() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        try store.pool.write { db in
            try db.execute(sql: """
                INSERT INTO threads(thread_id,title,project_name) VALUES ('a','任务 A','项目 A'),('b','任务 B','项目 A'),('c','任务 C',NULL);
                INSERT INTO usage(source_line,rollout_id,thread_id,account_id,usage_date,total_tokens,model,source,pricing_source) VALUES
                    (1,'a','a','account-a','2026-09-14',10,'model-a','local','{}'),
                    (1,'b','b','account-a','2026-09-14',20,'model-a','local','{}'),
                    (1,'c','c',NULL,'2026-09-14',30,NULL,'local','{}');
                INSERT INTO weekly_limit_cycles(id,account_id,limit_id,started_at,scheduled_reset_at,ended_at,reset_kind,last_observed_at,last_used_percent)
                    VALUES ('b','account-b','codex',0,604800,604800,'natural',600000,80);
                """)
        }
        let options = try store.usageFilterOptions()
        #expect(options.models == ["model-a"])
        #expect(options.projects == ["项目 A"])
        #expect(options.accounts == ["account-a", "account-b"])
    }

    @Test func groupCountIncludesAllPagesAndTracksFilters() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        try store.pool.write { db in
            try db.execute(sql: """
                INSERT INTO threads(thread_id,title) VALUES ('a','任务 A'),('b','任务 B');
                INSERT INTO usage(source_line,rollout_id,thread_id,usage_date,total_tokens,source,pricing_source) VALUES
                    (1,'a','a','2026-09-14',10,'local','{}'),
                    (1,'b','b','2026-09-14',20,'local','{}'),
                    (1,'c',NULL,'2026-09-14',30,'local','{}');
                """)
        }
        for offset in [0, 1, 2, 3] {
            let report = try store.usageReport(UsageQuery(grouping: .thread, timezone: "UTC", limit: 1, offset: offset))
            #expect(report.totalGroups == 3)
            #expect(report.hasMore == (offset < 2))
        }
        var filters = UsageFilters(); filters.search = "任务 A"
        let filtered = try store.usageReport(UsageQuery(grouping: .thread, timezone: "UTC", limit: 1, offset: 1, filters: filters))
        #expect(filtered.totalGroups == 1 && filtered.rows.isEmpty)
        filters.search = "不存在"
        #expect(try store.usageReport(UsageQuery(grouping: .thread, timezone: "UTC", filters: filters)).totalGroups == 0)
    }

    @Test func overviewKeepsTotalsChartsModelsAndRecentConversationsInTheSameRange() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        let now = try #require(DateParsing.parseTimestamp("2026-09-14T12:30:00Z"))
        let start = now.timeIntervalSince1970 - 86400
        try store.pool.write { db in
            try db.execute(sql: """
                INSERT INTO threads(thread_id,title,project_name) VALUES ('a','任务 A','项目 A'),('b','任务 B','项目 B');
                INSERT INTO usage(source_line,rollout_id,thread_id,account_id,occurred_at,usage_date,total_tokens,model,source,pricing_source) VALUES
                    (1,'old','b','a',?,'2026-09-13',1000,'m','local','{}'),
                    (1,'start','a','a',?,'2026-09-13',10,'m','local','{}'),
                    (1,'middle','b',NULL,?,'2026-09-13',20,NULL,'local','{}'),
                    (1,'end','a','a',?,'2026-09-14',30,'m','local','{}'),
                    (1,'future','b','a',?,'2026-09-14',2000,'m','local','{}'),
                    (1,'unknown',NULL,NULL,NULL,'2026-09-13',40,NULL,'local','{}');
                UPDATE usage SET input_amount = total_tokens * 3, input_tokens = total_tokens;
                """, arguments: [start - 1, start, start + 300, start + 86399, start + 86400])
        }
        for zone in ["UTC", "Asia/Shanghai", "America/Los_Angeles"] {
            let report = try store.overviewReport(period: .day, now: now, timezone: zone)
            #expect(report.total?.totalTokens == 30)
            #expect(report.total?.knownAmountNanoUSD == 90)
            #expect(report.models.reduce(0) { $0 + $1.totalTokens } == 30)
            #expect(report.trend.reduce(0) { $0 + $1.summary.totalTokens } == 30)
            #expect(report.trend.reduce(0) { $0 + ($1.summary.knownAmountNanoUSD ?? 0) } == 90)
            #expect(report.conversations.map(\.id) == ["a"])
            #expect(report.conversations.map { $0.summary.totalTokens } == [30])
            #expect(!report.hourly && report.trend.count == 1)
            for item in report.conversations {
                let rows = try store.usageRecords(report.query.focused(on: .thread, value: item.id)).rows
                #expect(rows.reduce(0) { $0 + $1.totalTokens } == item.summary.totalTokens)
            }
        }
        let history = try store.overviewReport(period: .all, now: now, timezone: "Asia/Shanghai")
        #expect(history.total?.totalTokens == 3100)
        #expect(history.unknownDateTokens == 40)
        #expect(history.trend.reduce(0) { $0 + $1.summary.totalTokens } == 3060)
        #expect(history.trend.count == 1 && !history.hourly)
    }

    @Test func unchangedRollingResultsKeepContentButExpiredRecordsChangeIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        let now = try #require(DateParsing.parseTimestamp("2026-09-14T12:30:00Z"))
        try store.pool.write { db in
            try db.execute(sql: """
                INSERT INTO usage(source_line,rollout_id,occurred_at,usage_date,total_tokens,source,pricing_source)
                VALUES(1,'test',?,'2026-09-14',100,'local','{}')
                """, arguments: [now.timeIntervalSince1970 - 60])
        }
        let first = try store.overviewReport(period: .day, now: now, timezone: "UTC")
        let unchanged = try store.overviewReport(period: .day, now: now.addingTimeInterval(60), timezone: "UTC")
        #expect(first.query != unchanged.query)
        #expect(first.hasSameContent(as: unchanged))
        let expired = try store.overviewReport(period: .day, now: now.addingTimeInterval(86400), timezone: "UTC")
        #expect(!first.hasSameContent(as: expired))
        let otherZone = try store.overviewReport(period: .day, now: now, timezone: "Asia/Shanghai")
        #expect(!first.hasSameContent(as: otherZone))
    }

    @Test func yearUsesMondayWeeksAndOtherPeriodsUseDaysOrMonths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        let now = try #require(DateParsing.parseTimestamp("2026-09-14T12:30:00Z"))
        try store.pool.write { db in
            for (index, time) in ["2026-09-13T18:00:00Z", "2026-09-14T02:00:00Z"].enumerated() {
                let date = try #require(DateParsing.parseTimestamp(time))
                try db.execute(sql: """
                    INSERT INTO usage(source_line,rollout_id,occurred_at,usage_date,total_tokens,input_tokens,input_amount,source,pricing_source)
                    VALUES(1,?,?,?,10,10,100,'local','{}')
                    """, arguments: [String(index), date.timeIntervalSince1970, String(time.prefix(10))])
            }
        }
        let year = try store.overviewReport(period: .year, now: now, timezone: "UTC")
        #expect(year.trend.map { $0.date.formatted(.iso8601.year().month().day()) } == ["2026-09-07", "2026-09-14"])
        #expect(year.trend.reduce(0) { $0 + $1.summary.totalTokens } == 20)
        #expect(year.trend.reduce(0) { $0 + ($1.summary.knownAmountNanoUSD ?? 0) } == 200)
        let shanghai = try store.overviewReport(period: .year, now: now, timezone: "Asia/Shanghai")
        #expect(shanghai.trend.count == 1 && shanghai.trend.first?.summary.totalTokens == 20)
        let day = try store.overviewReport(period: .day, now: now, timezone: "UTC")
        #expect(!day.hourly && day.trend.count == 1 && day.total?.totalTokens == 10)
        let all = try store.overviewReport(period: .all, now: now, timezone: "UTC")
        #expect(all.trend.count == 1 && all.trend.first?.summary.totalTokens == 20)
    }

    @Test func todayUsesMidnightOtherPeriodsRollAndHistoryHasNoTimeFilter() {
        let now = Date(timeIntervalSince1970: 20_000_000)
        for period in OverviewPeriod.allCases {
            let query = period.query(now: now, timezone: "UTC")
            if let days = period.days {
                #expect(query.filters.occurredBefore == now.timeIntervalSince1970)
                let start = period == .day ? floor(now.timeIntervalSince1970 / 86400) * 86400
                    : now.timeIntervalSince1970 - Double(days) * 86400
                #expect(query.filters.occurredFrom == start)
            } else { #expect(query.filters.isEmpty) }
            #expect(query.account == .all)
        }
    }

    @Test func todayRespectsTimezoneAndDaylightSaving() throws {
        for (zone, timestamp, midnight) in [
            ("Asia/Shanghai", "2026-09-14T18:30:00Z", "2026-09-14T16:00:00Z"),
            ("America/Los_Angeles", "2026-03-08T12:30:00Z", "2026-03-08T08:00:00Z"),
            ("America/Los_Angeles", "2026-11-01T12:30:00Z", "2026-11-01T07:00:00Z")
        ] {
            let now = try #require(DateParsing.parseTimestamp(timestamp))
            let start = try #require(DateParsing.parseTimestamp(midnight))
            let query = OverviewPeriod.day.query(now: now, timezone: zone)
            #expect(query.filters.occurredFrom == start.timeIntervalSince1970)
            #expect(query.filters.occurredBefore == now.timeIntervalSince1970)
        }
    }

}
