import Foundation
import GRDB
import Testing
@testable import TokenTickCore

struct LimitQueryTests {
    @Test func filtersAndStablePagesPreserveUnknownAmountsAndEvidence() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let all = try fixture.store.limitWindowPage()
        #expect(all.rows.count == 5 && !all.hasMore)
        var ids: [LimitWindow.ID] = []
        for offset in 0..<5 {
            let page = try fixture.store.limitWindowPage(LimitQuery(limit: 1, offset: offset))
            ids += page.rows.map(\.id)
            #expect(page.hasMore == (offset < 4))
        }
        #expect(ids == all.rows.map(\.id) && Set(ids).count == 5)
        let filtered = try fixture.store.limitWindowPage(LimitQuery(account: .account("a"), limitID: "codex", kind: .primary))
        #expect(filtered.rows.count == 2)
        #expect(try fixture.store.limitWindowPage(LimitQuery(account: .unknown)).rows.isEmpty)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(filtered.rows[0])) as? [String: Any])
        #expect(json["tokens"] is NSNull && json["inputAmount"] is NSNull && json["cacheReadAmount"] is NSNull)
        #expect(filtered.rows[0].sourceJSON == #"{"evidence":"kept"}"#)
        #expect(filtered.rows[0].lastUsedPercent == 123.5)
        #expect(try fixture.store.tableCounts()["statistics"] == 0)
    }

    @Test func inclusiveLocalDaysUseOverlapAndRespectDSTAndExactBoundaries() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let query = LimitQuery(timezone: "America/Los_Angeles", fromDate: "2026-03-08", throughDate: "2026-03-08")
        // 当地这一天只有 23 小时；正好在日初结束／次日开始的窗口不相交。
        let rows = try fixture.store.limitWindowPage(query).rows
        #expect(Set(rows.map(\.limitID)) == ["codex", "other"])
        #expect(rows.count == 3)
        let boundaries = try (query.boundary(query.fromDate, afterDay: false, timezone: TimeZone(identifier: "America/Los_Angeles")!),
                              query.boundary(query.throughDate, afterDay: true, timezone: TimeZone(identifier: "America/Los_Angeles")!))
        #expect(try #require(boundaries.1) - #require(boundaries.0) == 23 * 3_600)
        #expect(try fixture.store.limitWindowPage(LimitQuery(timezone: "UTC", fromDate: "2026-03-09", throughDate: "2026-03-09")).rows.count == 3)
        let instant = try #require(RolloutParser.parseDate("2011-12-30T10:00:00Z")).timeIntervalSince1970
        try fixture.store.pool.write { db in
            try db.execute(sql: """
                INSERT INTO limit_windows(account_id,limit_id,window_kind,starts_at,resets_at,window_duration_mins,used_percent,last_observed_at,source_json)
                VALUES ('a','skipped','primary',?,?,120,0,1,'{}')
                """, arguments: [instant - 3_600, instant + 3_600])
        }
        let skipped = LimitQuery(timezone: "Pacific/Apia", fromDate: "2011-12-30", throughDate: "2011-12-30")
        #expect(try fixture.store.limitWindowPage(skipped).rows.isEmpty)
    }

    @Test func latestSnapshotsAreAccountScopedAndMissingWindowsDoNotReturn() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try fixture.store.pool.write { db in
            try db.execute(sql: "INSERT INTO app_metadata(key,value) VALUES ('api_last_observed:a','200'), ('api_last_observed:b','100')")
        }
        let latest = try fixture.store.limitWindowPage(LimitQuery(latestOnly: true))
        #expect(latest.rows.count == 2)
        #expect(latest.rows.filter { $0.accountID == "a" }.map(\.kind) == ["primary"])
        #expect(try fixture.store.limitWindowPage(LimitQuery(account: .account("a"), kind: .secondary, latestOnly: true)).rows.isEmpty)
        try fixture.store.pool.write { db in
            try db.execute(sql: "UPDATE app_metadata SET value='300' WHERE key='api_last_observed:a'")
        }
        #expect(try fixture.store.limitWindowPage(LimitQuery(account: .account("a"), latestOnly: true)).rows.isEmpty)
        #expect(try fixture.store.limitWindows().count == 5)
    }

    @Test func invalidQueriesAreRejectedWithoutChangingFacts() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        for query in [LimitQuery(timezone: "bad/zone"), LimitQuery(fromDate: "2026-02-31"),
                      LimitQuery(fromDate: "2026-09-10", throughDate: "2026-09-09"), LimitQuery(limit: 0), LimitQuery(offset: -1)] {
            #expect(throws: UsageQueryError.self) { try fixture.store.limitWindowPage(query) }
        }
        #expect(try fixture.store.limitWindowPage(LimitQuery(offset: 5)).rows.isEmpty)
        #expect(try fixture.store.tableCounts()["limit_windows"] == 5)
    }

    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store: UsageStore
        init() throws {
            store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
            let times = try ["2026-03-08T07:00:00Z", "2026-03-08T08:00:00Z", "2026-03-08T09:00:00Z",
                             "2026-03-09T06:00:00Z", "2026-03-09T07:00:00Z", "2026-03-09T08:00:00Z"]
                .map { try #require(RolloutParser.parseDate($0)).timeIntervalSince1970 }
            try store.pool.write { db in
                for (account, bucket, kind, start, end, observed) in [
                    ("a", "before", "primary", 0, 1, 100),
                    ("a", "codex", "primary", 1, 2, 100),
                    ("a", "codex", "primary", 3, 4, 200),
                    ("a", "after", "secondary", 4, 5, 100),
                    ("b", "other", "secondary", 1, 3, 100)
                ] {
                    try db.execute(sql: """
                        INSERT INTO limit_windows(account_id,limit_id,window_kind,starts_at,resets_at,window_duration_mins,used_percent,last_observed_at,source_json)
                        VALUES (?,?,?,?,?,?,123.5,?,?);
                        """, arguments: [account,bucket,kind,Int64(times[start]),Int64(times[end]),Int64((times[end]-times[start])/60),observed,#"{"evidence":"kept"}"#])
                }
            }
        }
        func clean() { try? FileManager.default.removeItem(at: root) }
    }
}
