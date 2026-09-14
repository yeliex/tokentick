import Foundation
import GRDB
import Testing
@testable import TokenTickCore

struct OverviewReportTests {
    @Test func overviewKeepsTotalsChartsModelsAndRecentConversationsInTheSameRange() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        let now = try #require(DateParsing.parseTimestamp("2026-09-14T12:30:00Z"))
        let start = now.timeIntervalSince1970 - 86400
        try store.pool.write { db in
            try db.execute(sql: """
                INSERT INTO threads(thread_id,title,project_name) VALUES ('a','任务 A','项目 A'),('b','任务 B','项目 B');
                INSERT INTO usage(source_line,rollout_id,thread_id,account_id,occurred_at,usage_date,total_tokens,model,source,evidence_json) VALUES
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
            #expect(report.total?.totalTokens == 60)
            #expect(report.total?.knownAmountNanoUSD == 180)
            #expect(report.models.reduce(0) { $0 + $1.totalTokens } == 60)
            #expect(report.trend.reduce(0) { $0 + $1.summary.totalTokens } == 60)
            #expect(report.trend.reduce(0) { $0 + ($1.summary.knownAmountNanoUSD ?? 0) } == 180)
            #expect(report.conversations.map(\.id) == ["a", "b"])
            #expect(report.conversations.map { $0.summary.totalTokens } == [40, 20])
            #expect(!report.hourly && report.trend.count == 2)
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
                INSERT INTO usage(source_line,rollout_id,occurred_at,usage_date,total_tokens,source,evidence_json)
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
                    INSERT INTO usage(source_line,rollout_id,occurred_at,usage_date,total_tokens,input_tokens,input_amount,source,evidence_json)
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
        #expect(!day.hourly && day.trend.count == 2)
        let all = try store.overviewReport(period: .all, now: now, timezone: "UTC")
        #expect(all.trend.count == 1 && all.trend.first?.summary.totalTokens == 20)
    }

    @Test func sixPeriodsUseExactRollingDurationsAndHistoryHasNoTimeFilter() {
        let now = Date(timeIntervalSince1970: 20_000_000)
        for period in OverviewPeriod.allCases {
            let query = period.query(now: now, timezone: "UTC")
            if let days = period.days {
                #expect(query.filters.occurredBefore == now.timeIntervalSince1970)
                #expect(query.filters.occurredFrom == now.timeIntervalSince1970 - Double(days) * 86400)
            } else { #expect(query.filters.isEmpty) }
            #expect(query.account == .all)
        }
    }
}
