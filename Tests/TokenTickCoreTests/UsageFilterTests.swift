import Foundation
import GRDB
import Testing
@testable import TokenTickCore

struct UsageFilterTests {
    @Test func intersectionsMatchDetailsAcrossEveryGroupingAndDoNotRebuildCache() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        var filters = UsageFilters()
        filters.project = .value("项目 A"); filters.model = .value("m1"); filters.search = "CAFE"
        let query = UsageQuery(grouping: .total, timezone: "UTC", fromDate: "2026-09-09", throughDate: "2026-09-09", filters: filters)
        let records = try fixture.store.usageRecords(query).rows
        #expect(records.map(\.totalTokens) == [40, 20])
        for grouping in UsageGrouping.allCases {
            var grouped = query; grouped.grouping = grouping
            let report = try fixture.store.usageReport(grouped)
            #expect(report.rows.reduce(Int64(0)) { $0 + $1.totalTokens } == 60)
            for row in report.rows {
                let focused = grouped.focused(on: grouping, value: row.group)
                let details = try fixture.store.usageRecords(focused).rows
                #expect(details.reduce(Int64(0)) { $0 + $1.totalTokens } == row.totalTokens)
                #expect(details.count == row.records)
            }
        }
        #expect(try fixture.store.tableCounts()["statistics"] == 0)
        let conflict = try fixture.store.usageRecords(query, scope: .model("m2"))
        #expect(conflict.rows.isEmpty)
    }

    @Test func unknownValuesLiteralSearchAndLatestNamesRemainDistinct() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        var query = UsageQuery(grouping: .total, timezone: "UTC")
        query.filters.model = .unknown
        #expect(try fixture.store.usageReport(query).rows.first?.totalTokens == 90)
        query.filters.model = .value("unknown")
        #expect(try fixture.store.usageReport(query).rows.first?.totalTokens == 80)
        query.filters = UsageFilters(); query.filters.search = "%_"
        #expect(try fixture.store.usageRecords(query).rows.map(\.totalTokens) == [80])
        query.filters.search = "CAFÉ"
        #expect(try fixture.store.usageReport(query).rows.first?.totalTokens == 90)
        try fixture.store.pool.write { db in
            try db.execute(sql: "UPDATE threads SET title = '新任务', project_name = '项目 B' WHERE thread_id = 'a'")
        }
        #expect(try fixture.store.usageReport(query).rows.isEmpty)
        query.filters.search = "新任务"; query.filters.project = .value("项目 B")
        #expect(try fixture.store.usageReport(query).rows.first?.totalTokens == 90)
        query.filters.project = .value("项目 A")
        #expect(try fixture.store.usageRecords(query).rows.isEmpty)
    }

    @Test func filteredUnknownDatesFollowTimezoneAndRangesExcludeThem() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        var query = UsageQuery(grouping: .total, timezone: "Asia/Shanghai")
        query.filters.model = .unknown
        let all = try fixture.store.usageReport(query)
        #expect(all.unknownDateTokens == 90)
        query.fromDate = "2026-09-09"; query.throughDate = "2026-09-09"
        #expect(try fixture.store.usageReport(query).rows.isEmpty)
        #expect(try fixture.store.usageRecords(query).rows.isEmpty)
        query.fromDate = nil; query.throughDate = nil; query.filters.day = .unknown
        #expect(try fixture.store.usageRecords(query).rows.map(\.totalTokens) == [90])
        query.timezone = "UTC"
        #expect(try fixture.store.usageRecords(query).rows.isEmpty)
        query.filters.day = .value("2026-02-30")
        #expect(throws: UsageQueryError.self) { try fixture.store.usageReport(query) }
        #expect(throws: UsageQueryError.self) { try fixture.store.usageRecords(query) }
    }

    @Test func sortingHappensBeforeStablePaginationAndAmountsRemainPartial() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        for sort in UsageSort.allCases {
            var query = UsageQuery(grouping: .thread, timezone: "UTC", sort: sort)
            let whole = try fixture.store.usageReport(query)
            var groups = [String?]()
            query.limit = 1
            for index in whole.rows.indices {
                query.offset = index
                let page = try fixture.store.usageReport(query)
                groups += page.rows.map(\.group)
                #expect(page.hasMore == (index + 1 < whole.rows.count))
            }
            #expect(groups == whole.rows.map(\.group))
            query.offset = 0; query.limit = 100
            let details = try fixture.store.usageRecords(query)
            var ids = [Int64]()
            query.limit = 1
            for index in details.rows.indices {
                query.offset = index
                let page = try fixture.store.usageRecords(query)
                ids += page.rows.map(\.id)
                #expect(page.hasMore == (index + 1 < details.rows.count))
            }
            #expect(ids == details.rows.map(\.id) && Set(ids).count == 5)
        }
        let byAmount = try fixture.store.usageReport(UsageQuery(grouping: .thread, timezone: "UTC", sort: .amount))
        #expect(byAmount.rows.map(\.group) == ["b", "a", nil])
        #expect(byAmount.rows[1].knownAmountNanoUSD == 12 && byAmount.rows[1].unpricedRecords == 3)
        let byTokens = try fixture.store.usageRecords(UsageQuery(sort: .tokens))
        #expect(byTokens.rows.map(\.totalTokens) == [90, 80, 40, 30, 20])
    }

    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store: UsageStore
        init() throws {
            store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
            let time = try #require(DateParsing.parseTimestamp("2026-09-09T12:00:00Z")).timeIntervalSince1970
            try store.pool.write { db in
                try db.execute(sql: """
                    INSERT INTO threads(thread_id, title, project_name) VALUES ('a', 'Café 任务', '项目 A'), ('b', '%_真实字符', 'unknown');
                    INSERT INTO usage(source_line,rollout_id, thread_id, occurred_at, usage_date, total_tokens, model, source, pricing_source) VALUES
                      (1,'a', 'a', ?, '2026-09-09', 20, 'm1', 'local', '{}'),
                      (1,'b', 'a', ?, '2026-09-09', 30, 'm2', 'local', '{}'),
                      (1,'c', 'a', ?, '2026-09-09', 40, 'm1', 'local', '{}'),
                      (1,'d', 'b', ?, '2026-09-09', 80, 'unknown', 'local', '{}'),
                      (1,'e', NULL, NULL, '2026-09-09', 90, NULL, 'local', '{}');
                    UPDATE usage SET input_amount = 6 WHERE thread_id = 'a' AND model = 'm1';
                    UPDATE usage SET input_amount = 100, amount = 100 WHERE thread_id = 'b';
                    """, arguments: [time, time, time, time])
            }
        }
        func clean() { try? FileManager.default.removeItem(at: root) }
    }
}
