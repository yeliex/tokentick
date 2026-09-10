import Foundation
import GRDB
import Testing
@testable import TokenTickCore

struct LimitQueryTests {
    @Test func resetsUseChronologicalEvidenceAndKeepUnknownAccountsSeparate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        // 乱序插入仍按观测时间识别自然及提前重置；首条观测不是历史重置。
        for (scope, account, observed, reset, percent) in [
            ("account:a", "a" as String?, 201.0, 900, 0.0),
            ("account:a", "a", 100, 200, 80),
            ("account:a", "a", 300, 900, 50),
            ("account:a", "a", 350, 1000, 0),
            ("thread:x", nil, 100, 200, 90),
            ("thread:x", nil, 201, 900, 0),
            ("thread:y", nil, 110, 800, 1)
        ] {
            let snapshot = CurrentLimitSnapshot(accountID: account, observedAt: observed, source: "local", scopeKey: scope,
                windows: [CurrentLimitWindow(limitID: "codex", kind: "primary", usedPercent: percent, durationMinutes: 10080, resetsAt: Int64(reset))], sourceJSON: "{}")
            try store.pool.write { db throws -> Void in
                #expect(try UsageStore.saveWeeklyObservations(snapshot, db: db) == 1)
                #expect(try UsageStore.saveWeeklyObservations(snapshot, db: db) == 0)
            }
        }
        let rows = try store.weeklyLimitHistory().rows
        #expect(rows.count == 3)
        #expect(rows.first?.kind == "manual" && rows.first?.usedPercentBeforeReset == 50)
        #expect(rows.filter { $0.kind == "natural" }.count == 2)
        #expect(try store.weeklyLimitHistory(LimitQuery(account: .account("a"))).rows.count == 2)
        #expect(try store.weeklyLimitHistory(LimitQuery(account: .unknown)).rows.count == 1)
        var ids: [String] = []
        for offset in 0..<3 {
            let page = try store.weeklyLimitHistory(LimitQuery(limit: 1, offset: offset))
            ids += page.rows.map(\.id)
            #expect(page.hasMore == (offset < 2))
        }
        #expect(ids == rows.map(\.id) && Set(ids).count == 3)
        #expect(try store.weeklyLimitHistory(LimitQuery(limitID: "other")).rows.isEmpty)
        #expect(try UsageStore(databaseURL: store.databaseURL).weeklyLimitHistory().rows.map(\.id) == ids)
    }

    @Test func logOnlyQuotaBackfillsWeeklyHistoryWithoutTokenUsageOrDuplicateRescans() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let id = "00000000-0000-0000-0000-000000000091"
        var lines = ["{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(id)\"}}"]
        for (timestamp, reset, percent) in [("2026-09-09T23:59:00Z", 1788998400, 75), ("2026-09-10T00:01:00Z", 1789603200, 0)] {
            lines.append("{\"timestamp\":\"\(timestamp)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":null,\"rate_limits\":{\"limit_id\":\"codex\",\"primary\":{\"used_percent\":\(percent),\"window_minutes\":10080,\"resets_at\":\(reset)},\"secondary\":{\"used_percent\":10,\"window_minutes\":300,\"resets_at\":\(reset)}}}}")
        }
        let file = sessions.appendingPathComponent("rollout-2026-09-09T00-00-00-\(id).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        let report = try LocalUsageScanner(store: store).scan(codexHome: root)
        #expect(report.issueCount == 0 && report.insertedRequests == 0)
        #expect(report.currentLimits?.windows.count == 2)
        #expect(try store.tableCounts()["weekly_limit_observations"] == 2)
        #expect(try store.weeklyLimitHistory().rows.first?.usedPercentBeforeReset == 75)
        #expect(try store.weeklyLimitHistory(LimitQuery(fromDate: "2026-09-10", throughDate: "2026-09-10", account: .unknown)).rows.count == 1)
        #expect(try LocalUsageScanner(store: store).scan(codexHome: root).scannedFiles == 0)
        #expect(try store.tableCounts()["weekly_limit_observations"] == 2)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any]
        #expect(json?["currentLimits"] == nil)
    }

    @Test func localDatesRespectDSTAndInvalidQueriesAreRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        let query = LimitQuery(fromDate: "2026-03-08", throughDate: "2026-03-08")
        let zone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let start = try #require(try query.boundary(query.fromDate, afterDay: false, timezone: zone))
        let end = try #require(try query.boundary(query.throughDate, afterDay: true, timezone: zone))
        #expect(end - start == 23 * 3600)
        for query in [LimitQuery(timezone: "bad/zone"), LimitQuery(fromDate: "2026-02-31"),
                      LimitQuery(fromDate: "2026-09-10", throughDate: "2026-09-09"), LimitQuery(limit: 0), LimitQuery(offset: -1)] {
            #expect(throws: UsageQueryError.self) { try store.weeklyLimitHistory(query) }
        }
    }
}
