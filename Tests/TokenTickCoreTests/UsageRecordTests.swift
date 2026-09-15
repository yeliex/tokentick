import Foundation
import GRDB
import Testing
@testable import TokenTickCore

struct UsageRecordTests {
    @Test func detailsMatchStatisticsAcrossDSTAndKeepUnknownDistinctFromLiteralNames() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        for zone in ["UTC", "America/Los_Angeles"] {
            let query = UsageQuery(timezone: zone)
            let all = try fixture.store.usageRecords(query)
            #expect(all.rows.count == 4 && !all.hasMore)
            for grouping in [UsageGrouping.day, .thread, .project, .model] {
                let summaries = try fixture.store.usageReport(UsageQuery(grouping: grouping, timezone: zone)).rows
                for summary in summaries {
                    let scope: UsageRecordScope = switch grouping {
                    case .day: .day(summary.group)
                    case .thread: .thread(summary.group)
                    case .project: .project(summary.group)
                    default: .model(summary.group)
                    }
                    let records = try fixture.store.usageRecords(query, scope: scope).rows.filter { $0.source == "local" || $0.threadID != nil }
                    #expect(records.reduce(Int64(0)) { $0 + $1.totalTokens } == summary.totalTokens)
                    #expect(records.count == summary.records)
                }
            }
        }
        let query = UsageQuery(timezone: "America/Los_Angeles", fromDate: "2026-03-08", throughDate: "2026-03-08")
        let ranged = try fixture.store.usageRecords(query)
        #expect(ranged.rows.map(\.totalTokens) == [30, 20])
        #expect(ranged.rows.allSatisfy { $0.statisticalDate == "2026-03-08" })
        #expect(try fixture.store.usageRecords(query, scope: .day(nil)).rows.isEmpty)
        #expect(try fixture.store.usageRecords(UsageQuery(timezone: "UTC"), scope: .project("unknown")).rows.count == 2)
        #expect(try fixture.store.usageRecords(UsageQuery(timezone: "UTC"), scope: .project(nil)).rows.count == 2)
        #expect(try fixture.store.usageRecords(UsageQuery(account: .unknown)).rows.count == 3)
        #expect(try fixture.store.usageRecords(UsageQuery(account: .account("unknown"))).rows.count == 1)
    }

    @Test func stablePagesRetainExactPricesNullModesAndLatestMetadataAfterArchive() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let all = try fixture.store.usageRecords(UsageQuery(timezone: "UTC"))
        var ids = [Int64]()
        for offset in 0..<all.rows.count {
            let page = try fixture.store.usageRecords(UsageQuery(timezone: "UTC", limit: 1, offset: offset))
            ids += page.rows.map(\.id)
            #expect(page.hasMore == (offset + 1 < all.rows.count))
        }
        #expect(ids == all.rows.map(\.id) && Set(ids).count == 4)
        let before = try #require(all.rows.first(where: { $0.turnID == "turn-a" }))
        #expect(before.inputPrice == "0.1234567890123456789")
        #expect(before.isFast == true && before.isLongContext == true)
        #expect(before.inputAmountNanoUSD == 1 && before.amountNanoUSD == 7 && before.knownAmountNanoUSD == 7)
        try fixture.store.pool.write { db in
            try db.execute(sql: "UPDATE threads SET title = '新标题', project_name = '新项目' WHERE thread_id = 't'")
            try db.execute(sql: "UPDATE scan_files SET current_path = '/missing/archived_sessions/log.jsonl.zst' WHERE rollout_id = 'rollout'")
        }
        let after = try #require(fixture.store.usageRecords(UsageQuery(), scope: .project("新项目")).rows.first(where: { $0.id == before.id }))
        #expect(after.title == "新标题" && after.fileName == "log.jsonl")
        #expect(after.lastKnownPath == "/missing/archived_sessions/log.jsonl.zst")
        #expect(after.reasoningEffort == before.reasoningEffort && after.sourceLine == 3 && after.amountNanoUSD == 7)
        let unknown = try #require(all.rows.first(where: { $0.source == "api" }))
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(unknown)) as? [String: Any])
        #expect(json["tier"] is NSNull && json["amountNanoUSD"] is NSNull)
        #expect(json["inputPrice"] is NSNull && json["inputTokens"] is NSNull)
        #expect(unknown.knownAmountNanoUSD == nil)
    }

    @Test func invalidFiltersFailWithoutWritingOrRebuildingStatistics() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        for query in [UsageQuery(timezone: "invalid/zone"), UsageQuery(fromDate: "2026-02-31"),
                      UsageQuery(fromDate: "2026-09-02", throughDate: "2026-09-01"), UsageQuery(limit: 0), UsageQuery(offset: -1)] {
            #expect(throws: UsageQueryError.self) { try fixture.store.usageRecords(query) }
        }
        #expect(throws: UsageQueryError.self) { try fixture.store.usageRecords(scope: .day("bad")) }
        _ = try fixture.store.usageRecords()
        #expect(try fixture.store.tableCounts()["statistics"] == 0)
    }

    private struct Fixture {
        let root: URL
        let store: UsageStore
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
            let times = try ["2026-03-08T07:59:00Z", "2026-03-08T08:01:00Z", "2026-03-09T06:59:00Z"]
                .map { try #require(DateParsing.parseTimestamp($0)).timeIntervalSince1970 }
            try store.pool.write { db in
                try db.execute(sql: """
                    INSERT INTO threads(thread_id, title, project_name) VALUES ('t', '标题', 'unknown');
                    INSERT INTO scan_files(rollout_id, thread_id, file_name, current_path) VALUES ('rollout', 't', 'log.jsonl', '/missing/sessions/log.jsonl');
                    INSERT INTO usage(source_line,rollout_id, thread_id, occurred_at, usage_date, total_tokens, model, source, pricing_source) VALUES
                        (1,'a', 't', ?, '2026-03-08', 10, 'model', 'local', '{"mode":"priority"}'),
                        (1,'b', 't', ?, '2026-03-08', 20, NULL, 'local', '{}'),
                        (1,'c', NULL, ?, '2026-03-09', 30, 'unknown', 'local', '{}'),
                        (1,'d', NULL, NULL, '2026-03-08', 40, NULL, 'api', '{}');
                    UPDATE usage SET account_id = 'unknown' WHERE rollout_id = 'd';
                    UPDATE usage SET turn_id = 'turn-a', rollout_id = 'rollout', source_line = 3,
                        tier = 'fast', is_long_context = 1, input_price = '0.1234567890123456789',
                        input_amount = 1, output_amount = 2, cache_read_amount = 4, cache_write_amount = 0, amount = 7
                        WHERE rollout_id = 'a';
                    """, arguments: StatementArguments(times))
            }
        }
        func clean() { try? FileManager.default.removeItem(at: root) }
    }
}
