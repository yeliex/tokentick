import Foundation
import GRDB
import Testing
@testable import TokenTickCore

struct LimitQueryTests {
    @Test func idleZerosWaitForUsageAndRecoveryDiffersFromWindowStart() throws {
        let f = try Fixture(); defer { f.clean() }
        let week = 604800
        try f.add(100, week + 100, 100)
        for time in [1000,1300,1600] { try f.add(Double(time), week + time, 0) }
        var rows = try f.store.weeklyLimitHistory().rows
        #expect(rows.count == 1)
        // 第一条消息时的零值早于首次正用量；两者对应同一固定窗口。
        try f.add(1800, week + 1800, 0)
        try f.add(1900, week + 1800, 1)
        try f.add(2000, week + 1801, 2)
        rows = try f.store.weeklyLimitHistory().rows
        #expect(rows.count == 2)
        let window = try #require(rows.first)
        #expect(window.startedAtInferred == 1800 && window.firstObservedAt == 1800)
        #expect(window.firstPositiveAt == 1900 && window.recoveryObservedAt == 1000)
        #expect(window.lastUsedPercent == 2 && window.finalUsedPercent == nil)
        #expect(window.totalTokens == 0 && window.amountNanoUSD == 0)
        #expect(rows.last?.lastUsedPercent == 100)
        #expect(rows.last?.actualResetAt == 1000)
        #expect(rows.last?.endsAt == 1000)
        #expect(rows.last?.usageEndsAt == 1000)
        #expect(window.endsAt == Double(week + 1800))
    }

    @Test func earlyResetClosesUsageAtRecoveryWithoutBorrowingOtherAccounts() throws {
        let f = try Fixture(); defer { f.clean() }
        try f.add(100, 604900, 90)
        try f.add(1000.5, 605800, 0)
        try f.add(1900, 606600, 1)
        try f.store.pool.write { db in
            try db.execute(sql: """
                INSERT INTO usage(source_line,rollout_id,account_id,occurred_at,usage_date,total_tokens,amount,input_amount,source,evidence_json) VALUES
                    (1,'before','a',1000.25,'1970-01-01',10,5,5,'local','{}'),
                    (1,'after','a',1000.75,'1970-01-01',20,7,7,'local','{}');
                """)
        }
        let previous = try #require(f.store.weeklyLimitHistory().rows.last)
        #expect(previous.actualResetAt == 1000.5)
        #expect(previous.endsAt == 1000.5)
        #expect(previous.totalTokens == 10 && previous.amountNanoUSD == 5)
        #expect(previous.requestCount == 1)
        try f.add(200, 604950, 70, account: "b", scope: "account:b")
        let own = try #require(f.store.weeklyLimitHistory(LimitQuery(account: .account("b"))).rows.first)
        #expect(own.actualResetAt == nil && own.endsAt == 604950)
    }

    @Test func singleAccountHistoryClosesOlderCyclesAcrossUnknownObservations() throws {
        let f = try Fixture(); defer { f.clean() }
        try f.add(110, 604900, 90)
        try f.add(210, 605000, 10, account: nil, scope: "thread:x")
        try f.add(310, 605100, 5)
        let rows = try f.store.weeklyLimitHistory().rows
        #expect(rows.map(\.endsAt) == [605100, 300, 200])
        #expect(rows.filter { $0.endsAt > 400 }.count == 1)
        #expect(rows[1].accountID == nil)
        let page = try f.store.weeklyLimitHistory(LimitQuery(limit: 1, offset: 1))
        #expect(page.rows.first?.endsAt == 300)
    }

    @Test func deadlineJitterAndPercentDropsDoNotSplitAWindow() throws {
        let f = try Fixture(); defer { f.clean() }
        let week = 604800
        for (time,reset,percent) in [(100.0,week+100,40.0),(110,week+102,5),(120,week+113,41),
                                     (130,week+113,6),(140,week+113,7)] {
            try f.add(time,reset,percent)
        }
        let rows = try f.store.weeklyLimitHistory().rows
        #expect(rows.count == 1 && rows[0].scheduledResetAt == week+113)
        #expect(rows[0].lastUsedPercent == 7 && rows[0].peakUsedPercent == 41)
        #expect(rows[0].recoveryObservedAt == nil)
        // 同一天真正开始的另一窗口保留；不能按日合并。
        try f.add(4000,week+4000,0); try f.add(4010,week+4000,1)
        #expect(try f.store.weeklyLimitHistory().rows.count == 2)
    }

    @Test func earlierDeadlineEvidenceKeepsPublishedWindowIdentity() throws {
        let f = try Fixture(); defer { f.clean() }
        try f.add(100,700,10); try f.add(110,701,20)
        let before = try #require(f.store.weeklyLimitHistory().rows.first)
        try f.add(90,699,5)
        let after = try #require(f.store.weeklyLimitHistory().rows.first)
        #expect(after.id == before.id && after.firstObservedAt == 90 && after.lastUsedPercent == 20)
    }

    @Test func expiredForkAndKnownAccountDeadlineConflictsDoNotCreateWindows() throws {
        let f = try Fixture(); defer { f.clean() }
        try f.add(100, 200, 80)
        try f.add(201, 180, 5); try f.add(202, 190, 8)
        try f.add(203, 900, 2, exclusion: "fork_replay")
        try f.add(204, 900, 2, scope: "thread:one")
        try f.add(204, 800, 95, scope: "thread:two")
        let result = try f.store.weeklyLimitHistory()
        #expect(result.rows.count == 1 && result.rows[0].lastUsedPercent == 80)
        #expect(result.excludedObservations["expired"] == 2)
        #expect(result.excludedObservations["fork_replay"] == 1)
        #expect(result.excludedObservations["conflicting_deadlines"] == 2)
    }

    @Test func globalWindowMergesEvidenceWhileAccountQueriesNeverBorrowUnknownUsage() throws {
        let f = try Fixture(); defer { f.clean() }
        try f.add(100, 200, 80, account: nil, scope: "thread:x")
        try f.add(110, 201, 85, account: "a")
        var global = try f.store.weeklyLimitHistory().rows
        #expect(global.count == 1 && global[0].lastUsedPercent == 85)
        #expect(global[0].accountID == nil && global[0].unknownAccountObservations == 1)
        #expect(global[0].observedAccountIDs == ["a"])
        #expect(try f.store.weeklyLimitHistory(LimitQuery(account: .account("a"))).rows.first?.lastUsedPercent == 85)
        try f.add(120, 202, 90, account: nil, scope: "thread:y")
        global = try f.store.weeklyLimitHistory().rows
        #expect(global.count == 1 && global[0].lastUsedPercent == 90)
        #expect(try f.store.weeklyLimitHistory(LimitQuery(account: .account("a"))).rows.first?.lastUsedPercent == 85)
        #expect(try f.store.weeklyLimitHistory(LimitQuery(account: .account("b"))).rows.isEmpty)
        #expect(try f.store.weeklyLimitHistory(LimitQuery(account: .unknown)).rows.first?.lastUsedPercent == 90)
        try f.add(120, 202, 92, account: nil, scope: "thread:z")
        let conflict = try #require(f.store.weeklyLimitHistory().rows.first)
        #expect(conflict.lastUsedPercent == nil && conflict.conflictingObservations == 1)
        #expect(conflict.peakUsedPercent == 92)
    }

    @Test func anchoredToleranceDoesNotChainAndPaginationIsStableAfterLateObservations() throws {
        let f = try Fixture(); defer { f.clean() }
        for (time,reset) in [(100.0,700),(110,730),(120,760),(130,790)].reversed() {
            try f.add(time,reset,10)
        }
        let rows = try f.store.weeklyLimitHistory().rows
        #expect(rows.count == 2)
        var ids: [String] = []
        for offset in rows.indices {
            let page = try f.store.weeklyLimitHistory(LimitQuery(limit: 1, offset: offset))
            ids += page.rows.map(\.id)
            #expect(page.hasMore == (offset < rows.count - 1))
        }
        #expect(ids == rows.map(\.id) && Set(ids).count == rows.count)
        #expect(try UsageStore(databaseURL: f.store.databaseURL).weeklyLimitHistory().rows.map(\.id) == ids)
        try f.add(2_000_000, 2_000_100, 5)
        #expect(try f.store.weeklyLimitHistory().rows.count == 3)
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
        #expect(try f.store.weeklyLimitHistory().rows.count == 2)
        #expect(try f.store.tableCounts()["usage"] == 0)
    }

    @Test func newlyDiscoveredTurnOwnerInvalidatesQuotaCopiesWithoutChangingTokenFacts() throws {
        let f = try Fixture(); defer { f.clean() }
        try f.add(100,200,80,account:nil,scope:"thread:child",turn:"shared")
        #expect(try f.store.weeklyLimitHistory().rows.count == 1)
        try f.store.pool.write { db in
            try db.execute(sql: "INSERT INTO turn_usage(id,turn_id,thread_id,source_created_at,started_at,last_event_at) VALUES ('turn:shared','shared','parent',1,1,1)")
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
        #expect(rows.count == 1 && rows[0].limitID == "codex" && rows[0].lastUsedPercent == 80)
        #expect(try f.store.weeklyLimitHistory(LimitQuery(limitID: "codex_bengalfox")).rows.isEmpty)
    }

    @Test func approvedMonthLogSampleProducesTwelveWindowsAndTheirLastUsage() throws {
        let f = try Fixture(); defer { f.clean() }
        // 2026-08-10 至 09-10 已核对日志的起始、正用量及末尾观测，账号已匿名化。
        let observations: [(Double, Int, Double, String?)] = [
            (1786415513.645, 1787020305, 0, nil),
            (1786415632.137, 1787020308, 1, nil),
            (1786544108.538, 1787020308, 88, nil),
            (1786415646.982, 1787020308, 1, nil),
            (1786415652.986, 1787020308, 1, nil),
            (1786593765.714, 1787197186, 1, nil),
            (1787194850.402, 1787197187, 100, nil),
            (1786593809.952, 1787197186, 1, nil),
            (1786593816.673, 1787197186, 1, nil),
            (1787199823.959, 1787804607, 0, nil),
            (1787200514.570, 1787804612, 1, nil),
            (1787532223.128, 1787804612, 78, nil),
            (1787200518.008, 1787804612, 1, nil),
            (1787200521.137, 1787804612, 1, nil),
            (1787532231.520, 1788137022, 0, nil),
            (1787532761.460, 1788137022, 1, nil),
            (1787667179.303, 1788137022, 43, nil),
            (1787532779.354, 1788137022, 1, nil),
            (1787532783.135, 1788137022, 1, nil),
            (1787667193.979, 1788271979, 0, nil),
            (1787710809.187, 1788271986, 1, nil),
            (1787834244.658, 1788271986, 43, nil),
            (1787710813.524, 1788271986, 1, nil),
            (1787710960.965, 1788271986, 1, nil),
            (1787881147.562, 1788485938, 0, nil),
            (1787881309.045, 1788485947, 1, nil),
            (1787915756.196, 1788485947, 50, nil),
            (1787881315.844, 1788485947, 1, nil),
            (1787881317.243, 1788485947, 1, nil),
            (1788058312.541, 1788662655, 0, nil),
            (1788058693.655, 1788662655, 1, nil),
            (1788143316.686, 1788662655, 5, nil),
            (1788058715.449, 1788662655, 1, nil),
            (1788058724.101, 1788662655, 1, nil),
            (1788143318.043, 1788748109, 0, nil),
            (1788144899.900, 1788748118, 1, nil),
            (1788748112.449, 1788748118, 100, nil),
            (1788144902.788, 1788748118, 1, nil),
            (1788144911.593, 1788748118, 1, nil),
            (1788163084.880, 1788767880, 0, nil),
            (1788163087.903, 1788767884, 3, nil),
            (1788228574.368, 1788767884, 41, nil),
            (1788163090.548, 1788767884, 4, nil),
            (1788163093.065, 1788767884, 4, nil),
            (1788748133.354, 1789352923, 0, nil),
            (1788748476.051, 1789352923, 1, nil),
            (1788975581.749, 1789352923, 42, nil),
            (1788748483.243, 1789352923, 1, nil),
            (1788748489.758, 1789352923, 1, nil),
            (1788832193.437, 1789436850, 0, nil),
            (1788832364.723, 1789436850, 1, nil),
            (1788998601.495, 1789436850, 100, "a"),
            (1788832372.892, 1789436850, 1, nil),
            (1788832501.350, 1789436850, 1, nil),
            (1788999804.818, 1789604604, 0, "a"),
            (1789000441.342, 1789604620, 1, nil),
            (1789023905.214, 1789604620, 19, nil),
            (1789000448.918, 1789604620, 1, nil),
            (1789000454.505, 1789604620, 1, nil)
        ]
        for (time,reset,percent,account) in observations.reversed() {
            try f.add(time,reset,percent,account:account,scope:account.map { "account:" + $0 } ?? "thread:sample")
        }
        let rows = try f.store.weeklyLimitHistory(LimitQuery(timezone:"Asia/Shanghai",fromDate:"2026-08-10",throughDate:"2026-09-10")).rows.reversed()
        let expectedStarts: [Int64] = [1786415508, 1786592386, 1787199812, 1787532222, 1787667186, 1787881147, 1788057855, 1788143318, 1788163084, 1788748123, 1788832050, 1788999820]
        #expect(rows.count == 12)
        #expect(rows.map(\.lastUsedPercent) == [88,100,78,43,43,50,5,100,41,42,100,19])
        for (row,start) in zip(rows,expectedStarts) { #expect(abs(row.startedAtInferred-start)<=30) }
    }

    @Test func windowUsageUsesTurnStartAndInvalidatesAfterFactsChangeWithoutBorrowingAccounts() throws {
        let f = try Fixture(); defer { f.clean() }
        try f.add(110,604900,10)
        try f.add(210,605000,20)
        try f.store.pool.write { db in
            try db.execute(sql: """
                INSERT INTO turn_usage VALUES ('turn:x','x','t',50,150,250);
                INSERT INTO usage(source_line,rollout_id,turn_key,account_id,thread_id,turn_id,occurred_at,usage_date,total_tokens,amount,input_amount,source,evidence_json) VALUES
                    (1,'cross','turn:x','a','t','x',250,'1970-01-01',10,5,5,'local','{}'),
                    (1,'boundary',NULL,'a','t',NULL,200,'1970-01-01',20,7,7,'local','{}'),
                    (1,'unknown',NULL,NULL,'t',NULL,220,'1970-01-01',30,NULL,NULL,'local','{}'),
                    (1,'another',NULL,'b','t',NULL,230,'1970-01-01',40,9,9,'local','{}');
                """)
        }
        let known = try f.store.weeklyLimitHistory(LimitQuery(account: .account("a"))).rows.sorted { $0.startedAtInferred < $1.startedAtInferred }
        #expect(known.map(\.totalTokens) == [10,20])
        #expect(known.map(\.amountNanoUSD) == [5,7])
        #expect(known[0].usageEndsAt == 200)
        let all = try f.store.weeklyLimitHistory().rows.sorted { $0.startedAtInferred < $1.startedAtInferred }
        #expect(all.map(\.totalTokens) == [10,90])
        #expect(all[1].amountNanoUSD == nil && all[1].knownAmountNanoUSD == 16 && all[1].unpricedTokens == 30)
        try f.store.pool.write { try $0.execute(sql: "UPDATE usage SET total_tokens=21,amount=8,input_amount=8 WHERE rollout_id='boundary'") }
        let after = try f.store.weeklyLimitHistory(LimitQuery(account: .account("a"))).rows
        #expect(after.first?.totalTokens == 21 && after.first?.amountNanoUSD == 8)
        #expect(try f.store.weeklyLimitHistory(LimitQuery(account: .account("a"))).rows.first?.totalTokens == 21)
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
        #expect(try store.weeklyLimitHistory().rows.first?.lastUsedPercent == 75)
        #expect(try store.weeklyLimitHistory(LimitQuery(fromDate: "2026-09-03", throughDate: "2026-09-03", account: .unknown)).rows.count == 1)
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
