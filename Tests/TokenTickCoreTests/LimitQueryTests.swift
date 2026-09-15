import Foundation
import GRDB
import Testing
@testable import TokenTickCore

struct LimitQueryTests {
    private func snapshot(_ time: Double, reset: Int64, percent: Double, account: String? = "a") -> CurrentLimitSnapshot {
        CurrentLimitSnapshot(accountID: account, observedAt: time, source: "local", scopeKey: account.map { "account:" + $0 } ?? "unknown",
            windows: [.init(limitID: "codex", kind: "secondary", usedPercent: percent, durationMinutes: 10080, resetsAt: reset)], sourceJSON: "{}")
    }

    @Test func currentWindowIsMemoryOnlyAndEarlyResetDoesNotRequireZero() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        try store.observeWeeklyLimits([snapshot(200,reset:604900,percent:70)])
        try store.saveCompletedWeeklyCycles(now: Date(timeIntervalSince1970: 500))
        #expect(try store.weeklyLimitHistory().rows.isEmpty)
        try store.observeWeeklyLimits([snapshot(1000,reset:605800,percent:2)])
        try store.saveCompletedWeeklyCycles(now: Date(timeIntervalSince1970: 1001))
        let rows = try store.weeklyLimitHistory().rows
        #expect(rows.count == 1 && rows[0].resetKind == "early")
        #expect(rows[0].endsAt == 1000 && rows[0].lastUsedPercent == 70)
        let reopened = try UsageStore(databaseURL: store.databaseURL)
        #expect(try reopened.weeklyLimitHistory().rows == rows)
        #expect(reopened.weeklyMemory.withLock { $0.windows.isEmpty })
    }

    @Test func naturalResetAccountsAndReplayRemainIndependent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        let values = [snapshot(300,reset:604900,percent:80),snapshot(200,reset:604900,percent:30),
            snapshot(200,reset:604900,percent:20,account:"b")]
        try store.observeWeeklyLimits(values)
        try store.saveCompletedWeeklyCycles(now: Date(timeIntervalSince1970: 604901))
        let rows = try store.weeklyLimitHistory().rows
        #expect(rows.count == 2 && rows.allSatisfy { $0.resetKind == "natural" })
        #expect(try store.weeklyLimitHistory(LimitQuery(account: .account("a"))).rows.first?.lastUsedPercent == 80)
        try store.observeWeeklyLimits(values)
        #expect(try store.saveCompletedWeeklyCycles(now: Date(timeIntervalSince1970: 604901)) == 0)
    }

    @Test(arguments: [false, true]) func restartRestoresPreviousWindowAndNewLogClosesItOnce(separateFile: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let thread = "00000000-0000-0000-0000-000000000099"
        let file = sessions.appendingPathComponent("rollout-2026-09-01T00-00-00-\(thread).jsonl")
        let now = Date().timeIntervalSince1970
        func event(_ time: Double, reset: Int64, percent: Int, count: Int) -> String {
            let timestamp = Date(timeIntervalSince1970: time).formatted(.iso8601)
            return """
                {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\(count*100),"output_tokens":0,"total_tokens":\(count*100)},"last_token_usage":{"input_tokens":100,"output_tokens":0,"total_tokens":100}},"rate_limits":{"secondary":{"used_percent":\(percent),"window_minutes":10080,"resets_at":\(reset)}}}}

                """
        }
        let first = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(thread)\"}}\n"
            + event(now-100, reset: Int64(now)+500000, percent: 80, count: 1)
        try Data(first.utf8).write(to: file)
        let url = root.appendingPathComponent("usage.sqlite")
        let store = try UsageStore(databaseURL: url)
        _ = try LocalUsageScanner(store: store).scan(codexHome: root)
        #expect(try store.weeklyLimitHistory().rows.isEmpty)
        let reopened = try UsageStore(databaseURL: url)
        let unchanged = try LocalUsageScanner(store: reopened).scan(codexHome: root)
        #expect(unchanged.scannedFiles == 0 && unchanged.scannedBytes == 0)
        let secondThread = "00000000-0000-0000-0000-000000000098"
        let secondFile = sessions.appendingPathComponent("rollout-2026-09-01T00-00-00-\(secondThread).jsonl")
        if separateFile {
            try Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(secondThread)\"}}\n".utf8).write(to: secondFile)
        }
        let handle = try FileHandle(forWritingTo: separateFile ? secondFile : file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(event(now-50, reset: Int64(now)+550000, percent: 3, count: 2).utf8))
        // Preserve window state across commits, including a subsequent batch with no limit observations.
        try handle.write(contentsOf: Data(String(repeating: "{\"type\":\"other\"}\n", count: 520).utf8))
        try handle.close()
        #expect(try LocalUsageScanner(store: reopened).scan(codexHome: root).insertedRequests == 1)
        let rows = try reopened.weeklyLimitHistory().rows
        #expect(rows.count == 1 && rows[0].resetKind == "early")
        let third = try UsageStore(databaseURL: url)
        #expect(try LocalUsageScanner(store: third).scan(codexHome: root).insertedRequests == 0)
        #expect(try third.weeklyLimitHistory().rows == rows)
        #expect(try third.tableCounts()["usage"] == 2)
        let checkpoint = try #require(try third.scanCursor(rolloutID: separateFile ? secondThread : thread))
        #expect(checkpoint.state.weeklyWindows?.count == 1)
        #expect(checkpoint.state.weeklyWindows?.first?.percent == 3)
        let next = try FileHandle(forWritingTo: separateFile ? secondFile : file)
        try next.seekToEnd()
        try next.write(contentsOf: Data(event(now-20, reset: Int64(now)+590000, percent: 1, count: 3).utf8))
        try next.close()
        _ = try LocalUsageScanner(store: third).scan(codexHome: root)
        let finalRows = try third.weeklyLimitHistory().rows
        #expect(finalRows.count == 2)
        let fourth = try UsageStore(databaseURL: url)
        #expect(try LocalUsageScanner(store: fourth).scan(codexHome: root).scannedBytes == 0)
        #expect(try fourth.weeklyLimitHistory().rows == finalRows)
    }

    @Test func cycleSummariesPersistAndRefreshAfterLateUsageAndBoundaryChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        try store.pool.write { db in
            try db.execute(sql: """
                INSERT INTO usage(source_line,rollout_id,account_id,source,occurred_at,turn_key,turn_started_at,total_tokens,amount,input_amount) VALUES
                    (1,'a','a','local',200,'turn:x',200,10,100,100),
                    (2,'a','a','local',1200,'turn:x',1200,20,NULL,50),
                    (3,'b','b','local',300,NULL,NULL,99,900,900),
                    (4,'a','a','local',1500,NULL,NULL,40,400,400);
                """)
        }
        try store.observeWeeklyLimits([snapshot(200,reset:604900,percent:70)])
        try store.saveCompletedWeeklyCycles(now: Date(timeIntervalSince1970: 604901))
        #expect(try store.weeklyLimitHistory().rows.first?.totalTokens == 70)
        try store.observeWeeklyLimits([snapshot(1000,reset:605800,percent:2)])
        try store.saveCompletedWeeklyCycles(now: Date(timeIntervalSince1970: 1001))
        let early = try #require(store.weeklyLimitHistory().rows.first)
        #expect(early.endsAt == 1000 && early.totalTokens == 30 && early.requestCount == 2)
        #expect(early.amountNanoUSD == nil && early.knownAmountNanoUSD == 150)
        try store.pool.write { db in
            try db.execute(sql: "UPDATE usage SET amount=50 WHERE source_line=2 AND rollout_id='a'")
            try db.execute(sql: """
                INSERT INTO usage(source_line,rollout_id,account_id,source,occurred_at,total_tokens,amount,input_amount)
                VALUES (5,'a','a','local',500,5,25,25)
                """)
        }
        try store.saveCompletedWeeklyCycles(now: Date(timeIntervalSince1970: 1001))
        let updated = try #require(store.weeklyLimitHistory().rows.first)
        #expect(updated.totalTokens == 35 && updated.requestCount == 3)
        #expect(updated.amountNanoUSD == 175 && updated.knownAmountNanoUSD == 175)
        // History queries read persisted cycle totals directly, including after restart.
        try store.pool.write { try $0.execute(sql: "DROP TABLE usage") }
        let reopened = try UsageStore(databaseURL: store.databaseURL)
        #expect(try reopened.weeklyLimitHistory().rows == [updated])
    }

    @Test func excludedAndNonWeeklyWindowsDoNotCreateCycles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        var inherited = snapshot(200,reset:604900,percent:80); inherited.historyExclusion = "inherited"
        let short = CurrentLimitSnapshot(accountID: "a", observedAt: 200, source: "local", scopeKey: "account:a",
            windows: [.init(limitID: "codex",kind:"primary",usedPercent:20,durationMinutes:300,resetsAt:18200)], sourceJSON:"{}")
        try store.observeWeeklyLimits([inherited,short])
        try store.saveCompletedWeeklyCycles()
        #expect(try store.weeklyLimitHistory().rows.isEmpty)
    }
}
