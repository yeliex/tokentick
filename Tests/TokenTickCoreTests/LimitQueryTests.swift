import Foundation
import GRDB
import Testing
@testable import TokenTickCore

struct LimitQueryTests {
    @Test func naturalAndEarlyRecoveryUseConfirmedAccountTimelineAndStablePagination() throws {
        let f = try Fixture(); defer { f.clean() }
        // 第二次零值是独立后续观测；未使用新窗口的截止漂移不形成额外重置。
        for (time, reset, percent) in [(100.0, 200, 80.0), (201, 900, 0), (300, 900, 50),
                                       (350, 1000, 0), (360, 1010, 0), (370, 1020, 0), (400, 1100, 2)].reversed() {
            try f.add(time, reset, percent)
        }
        let rows = try f.store.weeklyLimitHistory().rows
        #expect(rows.filter { $0.kind == "natural" }.count == 1)
        let early = try #require(rows.first { $0.kind == "manual_suspected" })
        #expect(early.usedPercentBeforeReset == 50 && early.resetAfter == 300 && early.resetBefore == 350)
        #expect(early.confirmedAt == 360 && early.resetAt == nil && early.finalUsedPercent == nil)
        #expect(early.totalTokens == nil && early.amountNanoUSD == nil)
        var ids: [String] = []
        for offset in rows.indices {
            let page = try f.store.weeklyLimitHistory(LimitQuery(limit: 1, offset: offset))
            ids += page.rows.map(\.id)
            #expect(page.hasMore == (offset < rows.count - 1))
        }
        #expect(ids == rows.map(\.id) && Set(ids).count == rows.count)
        #expect(try f.store.weeklyLimitHistory(LimitQuery(account: .unknown)).rows.isEmpty)
        #expect(try f.store.weeklyLimitHistory(LimitQuery(limitID: "other")).rows.isEmpty)
        #expect(try UsageStore(databaseURL: f.store.databaseURL).weeklyLimitHistory().rows.map(\.id) == ids)
    }

    @Test func isolatedDropDoesNotReplaceLastCredibleUsageAndSustainedSameDeadlineIsUnconfirmed() throws {
        let f = try Fixture(); defer { f.clean() }
        for (time, percent) in [(100.0,40.0),(110,5),(120,41)] { try f.add(time, 700, percent) }
        var rows = try f.store.weeklyLimitHistory().rows
        #expect(rows.count == 1 && rows[0].kind == "observed")
        #expect(rows[0].usedPercentBeforeReset == 41 && rows[0].peakUsedPercent == 41)
        try f.add(130, 700, 6); try f.add(140, 700, 7)
        rows = try f.store.weeklyLimitHistory().rows
        #expect(rows.contains { $0.kind == "drop_unconfirmed" && $0.usedPercentBeforeReset == 41 })
        #expect(!rows.contains { $0.kind == "manual_suspected" || $0.kind == "natural" })
    }

    @Test func expiredForkAndSameInstantConflictsDoNotGenerateResets() throws {
        let f = try Fixture(); defer { f.clean() }
        try f.add(100, 200, 80)
        try f.add(201, 180, 5)
        try f.add(202, 190, 8)
        try f.add(203, 900, 0, exclusion: "fork_replay")
        try f.add(204, 900, 0, scope: "thread:one")
        try f.add(204, 800, 95, scope: "thread:two")
        let result = try f.store.weeklyLimitHistory()
        #expect(result.rows.count == 1 && result.rows[0].kind == "observed")
        #expect(result.rows[0].usedPercentBeforeReset == 80)
        #expect(result.excludedObservations["expired"] == 2)
        #expect(result.excludedObservations["fork_replay"] == 1)
        #expect(result.excludedObservations["conflicting_or_isolated_drop_points"] == 1)
    }

    @Test func unknownWindowsMergeEvidenceWithoutClaimingAnAccountOrReset() throws {
        let f = try Fixture(); defer { f.clean() }
        try f.add(100, 200, 80, account: nil, scope: "thread:x")
        try f.add(110, 201, 85, account: nil, scope: "thread:y")
        try f.add(110, 200, 90, account: nil, scope: "thread:z")
        let rows = try f.store.weeklyLimitHistory(LimitQuery(account: .unknown)).rows
        #expect(rows.count == 1 && rows[0].kind == "unattributed")
        #expect(rows[0].accountID == nil && rows[0].usedPercentBeforeReset == nil)
        #expect(rows[0].peakUsedPercent == 90 && rows[0].observationCount == 3)
        #expect(try f.store.weeklyLimitHistory(LimitQuery(account: .account("a"))).rows.isEmpty)
        try f.add(120, 200, 91, account: nil, scope: "thread:x")
        try f.add(120, 200, 92, account: nil, scope: "thread:y")
        let conflict = try #require(f.store.weeklyLimitHistory(LimitQuery(account: .unknown)).rows.first)
        #expect(conflict.usedPercentBeforeReset == nil && conflict.conflictingObservations > 0)
    }

    @Test func deadlineToleranceIsAnchoredAndGapsDoNotInventWeeklyResets() throws {
        let f = try Fixture(); defer { f.clean() }
        for (time,reset,percent) in [(100.0, 700, 10.0),(110,701,11),(120,702,12),(130,703,13)] {
            try f.add(time,reset,percent)
        }
        let rows = try f.store.weeklyLimitHistory().rows
        #expect(rows.count == 2 && rows.contains { $0.kind == "boundary_changed" })
        #expect(!rows.contains { $0.kind == "natural" })
        try f.add(2_000_000, 2_000_100, 5)
        #expect(try f.store.weeklyLimitHistory().rows.filter { $0.kind == "gap_unconfirmed" }.count == 1)
    }

    @Test func failedCachePublicationRollsBackAndRebuildDoesNotAlterUsage() throws {
        let f = try Fixture(); defer { f.clean() }
        try f.add(100,200,80)
        _ = try f.store.weeklyLimitHistory()
        let before = try f.store.pool.read { try Row.fetchAll($0, sql: "SELECT * FROM weekly_limit_cycles") }
        try f.add(201,900,5)
        try f.store.pool.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_weekly BEFORE INSERT ON weekly_limit_cycles BEGIN SELECT RAISE(ABORT,'test'); END")
        }
        #expect(throws: (any Error).self) { try f.store.weeklyLimitHistory() }
        #expect(try f.store.pool.read { try Row.fetchAll($0, sql: "SELECT * FROM weekly_limit_cycles") } == before)
        try f.store.pool.write { try $0.execute(sql: "DROP TRIGGER fail_weekly") }
        #expect(try f.store.weeklyLimitHistory().rows.contains { $0.kind == "natural" })
        #expect(try f.store.tableCounts()["usage"] == 0)
    }

    @Test func newlyDiscoveredTurnOwnerInvalidatesQuotaCopiesWithoutChangingTokenFacts() throws {
        let f = try Fixture(); defer { f.clean() }
        try f.add(100,200,80,account:nil,scope:"thread:child",turn:"shared")
        #expect(try f.store.weeklyLimitHistory().rows.count == 1)
        try f.store.pool.write { db in
            try db.execute(sql: "INSERT INTO turn_usage(id,turn_id,thread_id,source_created_at,started_at,last_event_at,seen_json) VALUES ('turn:shared','shared','parent',1,1,1,'{}')")
        }
        let result = try f.store.weeklyLimitHistory()
        #expect(result.rows.isEmpty && result.excludedObservations["fork_turn"] == 1)
        #expect(try f.store.tableCounts()["usage"] == 0)
    }

    @Test func historyOnlyUsesMainWeeklyBucketRegardlessOfPrimarySecondaryPosition() throws {
        let f = try Fixture(); defer { f.clean() }
        let snapshot = CurrentLimitSnapshot(accountID: "a", observedAt: 100, source: "api", scopeKey: "account:a", windows: [
            .init(limitID: "codex", kind: "primary", usedPercent: 80, durationMinutes: 10080, resetsAt: 200),
            .init(limitID: "codex", kind: "secondary", usedPercent: 20, durationMinutes: 300, resetsAt: 200),
            .init(limitID: "codex_bengalfox", kind: "secondary", usedPercent: 30, durationMinutes: 10080, resetsAt: 200)
        ], sourceJSON: "{}")
        try f.store.pool.write { db in
            #expect(try UsageStore.saveWeeklyObservations(snapshot, db: db) == 1)
            // 旧版本已保存的附加桶也不能进入新历史结果。
            try db.execute(sql: "INSERT INTO weekly_limit_observations(id,scope_key,account_id,limit_id,observed_at,resets_at,used_percent,source_json) VALUES ('old-extra','account:a','a','codex_bengalfox',100,200,30,'{}')")
        }
        #expect(snapshot.windows.count == 3)
        let rows = try f.store.weeklyLimitHistory().rows
        #expect(rows.count == 1 && rows[0].limitID == "codex" && rows[0].usedPercentBeforeReset == 80)
        #expect(try f.store.weeklyLimitHistory(LimitQuery(limitID: "codex_bengalfox")).rows.isEmpty)
    }

    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store: UsageStore
        init() throws { store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite")) }
        func clean() { try? FileManager.default.removeItem(at: root) }
        func add(_ time: Double, _ reset: Int, _ percent: Double, account: String? = "a", scope: String = "account:a", exclusion: String? = nil, turn: String? = nil) throws {
            var snapshot = CurrentLimitSnapshot(accountID: account, observedAt: time, source: "api", scopeKey: scope,
                windows: [.init(limitID: "codex", kind: "secondary", usedPercent: percent, durationMinutes: 10080, resetsAt: Int64(reset))], sourceJSON: "{}")
            snapshot.historyExclusion = exclusion
            snapshot.turnID = turn
            try store.pool.write { db in _ = try UsageStore.saveWeeklyObservations(snapshot, db: db) }
        }
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
