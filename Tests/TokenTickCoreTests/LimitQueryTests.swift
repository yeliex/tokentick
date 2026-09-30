import Foundation
import GRDB
import Testing
@testable import TokenTickCore

struct LimitQueryTests {
    private func snapshot(_ time: Double, reset: Int64, percent: Double, account: String? = "a", start: Double? = nil) -> CurrentLimitSnapshot {
        CurrentLimitSnapshot(accountID: account, observedAt: time, source: "local", scopeKey: account.map { "account:" + $0 } ?? "unknown",
            windows: [.init(limitID: "codex", kind: "secondary", usedPercent: percent, durationMinutes: 10080, resetsAt: reset)], sourceJSON: "{}",
            turnStartedAt: start ?? time)
    }

    @Test func deadlinesAndFirstObservationsAllowIdleGaps() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        try store.observeWeeklyLimits([snapshot(200,reset:1000,percent:70,start:150)])
        try store.saveCompletedWeeklyCycles(now: Date(timeIntervalSince1970: 999))
        #expect(try store.weeklyLimitHistory().rows.isEmpty)
        try store.saveCompletedWeeklyCycles(now: Date(timeIntervalSince1970: 1000))
        try store.observeWeeklyLimits([snapshot(5000,reset:9000,percent:2,start:4900)])
        try store.saveCompletedWeeklyCycles(now: Date(timeIntervalSince1970: 9000))
        let rows = try store.weeklyLimitHistory().rows.sorted { $0.startedAtInferred < $1.startedAtInferred }
        #expect(rows.count == 2)
        #expect(rows.first?.startedAtInferred == 200 && rows.first?.endsAt == 1000)
        #expect(rows.last?.startedAtInferred == 5000 && rows.last?.endsAt == 9000)
    }

    @Test func resetDriftAcrossRestartUpdatesOneCycle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("usage.sqlite")
        let store = try UsageStore(databaseURL: url)
        try store.observeWeeklyLimits([snapshot(300,reset:1000,percent:80,start:200)])
        try store.saveCompletedWeeklyCycles(now: Date(timeIntervalSince1970: 2000))
        let reopened = try UsageStore(databaseURL: url)
        try reopened.observeWeeklyLimits([snapshot(400,reset:1001,percent:95,start:250), snapshot(250,reset:1000,percent:30,start:100)])
        try reopened.saveCompletedWeeklyCycles(now: Date(timeIntervalSince1970: 2000))
        let rows = try reopened.weeklyLimitHistory().rows
        #expect(rows.count == 1)
        #expect(rows.first?.startedAtInferred == 250 && rows.first?.lastUsedPercent == 95)
        #expect(try reopened.saveCompletedWeeklyCycles(now: Date(timeIntervalSince1970: 2000)) == 0)
    }

    @Test func interleavedWindowsDoNotEndBeforeTheirDeadlines() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        try store.observeWeeklyLimits([snapshot(200,reset:1000,percent:70),snapshot(300,reset:2000,percent:2),snapshot(400,reset:1001,percent:80)])
        try store.saveCompletedWeeklyCycles(now: Date(timeIntervalSince1970: 500))
        #expect(try store.weeklyLimitHistory().rows.isEmpty)
        try store.saveCompletedWeeklyCycles(now: Date(timeIntervalSince1970: 3000))
        let rows = try store.weeklyLimitHistory().rows.sorted { $0.endsAt < $1.endsAt }
        #expect(rows.count == 1)
        #expect(rows.first?.endsAt == 1001 && rows.first?.lastUsedPercent == 80)
    }

    @Test func confirmedEarlyResetAndBackwardConflictAreIndependent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        let values = [snapshot(200,reset:1000,percent:80,start:100),
            snapshot(300,reset:2000,percent:2,start:100),snapshot(400,reset:2000,percent:4,start:100),
            snapshot(500,reset:1500,percent:40,start:490)]
        try store.observeWeeklyLimits([values[0],values[1]])
        try store.saveCompletedWeeklyCycles(now: Date(timeIntervalSince1970: 600))
        #expect(try store.weeklyLimitHistory().rows.isEmpty)
        try store.observeWeeklyLimits([values[2],values[3]])
        try store.saveCompletedWeeklyCycles(now: Date(timeIntervalSince1970: 3000))
        let rows = try store.weeklyLimitHistory().rows.sorted { $0.endsAt < $1.endsAt }
        #expect(rows.count == 2)
        #expect(rows.first?.resetKind == "early" && rows.first?.endsAt == 300)
        #expect(rows.last?.startedAtInferred == 300 && rows.last?.endsAt == 2000)
        var reversed = WeeklyCycleCalculator()
        for value in values.reversed() { reversed.consume(value) }
        try store.pool.write { db in _ = try reversed.saveCompleted(db: db, now: 3000) }
        #expect(try store.weeklyLimitHistory().rows.sorted { $0.endsAt < $1.endsAt } == rows)
    }

    @Test func lateOldWindowDoesNotUndoConfirmedResetAfterRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        var evidence = WeeklyCycleCalculator()
        // File A contains an old-window response after file B has established a reset.
        for value in [snapshot(100,reset:1000,percent:0),snapshot(200,reset:1000,percent:80),snapshot(600,reset:1000,percent:1),
                      snapshot(300,reset:2000,percent:2),snapshot(500,reset:2000,percent:4)] {
            evidence.consume(value)
        }
        var state = RolloutParserState(); state.weeklyWindows = evidence.windows
        let json = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        try store.pool.write { db in
            try db.execute(sql: "INSERT INTO scan_files(rollout_id,thread_id,file_name,parser_state_json) VALUES ('a','a','a.jsonl',?)", arguments: [json])
        }
        let reopened = try UsageStore(databaseURL: store.databaseURL)
        try reopened.restoreWeeklyWindows()
        try reopened.saveCompletedWeeklyCycles(now: Date(timeIntervalSince1970: 3000))
        let rows = try reopened.weeklyLimitHistory().rows.sorted { $0.endsAt < $1.endsAt }
        #expect(rows.count == 2)
        #expect(rows.first?.endsAt == 300 && rows.first?.lastUsedPercent == 80)
        #expect(rows.last?.startedAtInferred == 300 && rows.last?.lastUsedPercent == 4)
        #expect(try reopened.saveCompletedWeeklyCycles(now: Date(timeIntervalSince1970: 3000)) == 0)
    }

    @Test func continuedOldCycleGrowthDisprovesEarlyResetAcrossRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        var evidence = WeeklyCycleCalculator()
        let initial = [snapshot(100,reset:1000,percent:6),
                       snapshot(200,reset:1500,percent:0),snapshot(300,reset:1500,percent:9)]
        for value in initial { evidence.consume(value) }
        try store.pool.write { _ = try evidence.saveCompleted(db: $0, now: 4000) }
        #expect(try store.weeklyLimitHistory().rows.count == 2)
        for value in [snapshot(400,reset:1000,percent:7),snapshot(600,reset:1500,percent:41),
                      snapshot(610,reset:1000,percent:10),snapshot(990,reset:1000,percent:100),
                      snapshot(1010,reset:2000,percent:0),snapshot(1100,reset:2000,percent:40),
                      snapshot(1200,reset:3000,percent:0),snapshot(1300,reset:3000,percent:2),
                      snapshot(1400,reset:2000,percent:42),snapshot(1500,reset:3000,percent:10)] {
            evidence.consume(value)
        }
        var state = RolloutParserState(); state.weeklyWindows = evidence.windows
        let json = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        try store.pool.write {
            try $0.execute(sql: "INSERT INTO scan_files(rollout_id,thread_id,file_name,parser_state_json) VALUES ('a','a','a.jsonl',?)", arguments: [json])
        }
        let reopened = try UsageStore(databaseURL: store.databaseURL)
        try reopened.restoreWeeklyWindows()
        try reopened.saveCompletedWeeklyCycles(now: Date(timeIntervalSince1970: 4000))
        let rows = try reopened.weeklyLimitHistory().rows.sorted { $0.startedAtInferred < $1.startedAtInferred }
        #expect(rows.count == 3)
        #expect(rows[0].endsAt == 1000 && rows[0].lastUsedPercent == 100 && rows[0].resetKind == "natural")
        #expect(rows[1].startedAtInferred == 1010 && rows[1].endsAt == 1200 && rows[1].resetKind == "early")
        #expect(rows[2].startedAtInferred == 1200 && rows[2].endsAt == 3000)
        #expect(try reopened.saveCompletedWeeklyCycles(now: Date(timeIntervalSince1970: 4000)) == 0)
    }

    @Test func zeroOnlyCandidateDoesNotBlockFollowingCycles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        try store.observeWeeklyLimits([
            snapshot(100,reset:1000,percent:28),
            snapshot(200,reset:1500,percent:0),snapshot(210,reset:1500,percent:0),
            snapshot(300,reset:2000,percent:0),snapshot(310,reset:2000,percent:0),snapshot(400,reset:2000,percent:3),
            snapshot(500,reset:2500,percent:0),snapshot(510,reset:2500,percent:2)])
        try store.saveCompletedWeeklyCycles(now: Date(timeIntervalSince1970: 3000))
        let rows = try store.weeklyLimitHistory().rows.sorted { $0.startedAtInferred < $1.startedAtInferred }
        #expect(rows.count == 3)
        #expect(rows[0].endsAt == 300)
        #expect(rows[1].startedAtInferred == 300 && rows[1].endsAt == 500)
        #expect(rows[2].startedAtInferred == 500)
    }

    @Test func cycleTotalsUseMessageTimesAndExcludeIdleGaps() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        try store.pool.write { db in
            try db.execute(sql: """
                INSERT INTO usage(source_line,rollout_id,account_id,source,occurred_at,turn_key,turn_started_at,total_tokens,amount,input_amount) VALUES
                    (1,'a','a','local',200,'turn:x',200,10,100,100),
                    (2,'a','a','local',1200,'turn:x',200,20,NULL,50),
                    (3,'a','a','local',1500,NULL,1500,40,400,400),
                    (4,'a','a','local',2000,NULL,2000,50,500,500),
                    (5,'b','b','local',300,NULL,300,99,900,900);
                """)
        }
        try store.observeWeeklyLimits([snapshot(200,reset:1000,percent:70,start:200),snapshot(2000,reset:3000,percent:2,start:2000)])
        try store.saveCompletedWeeklyCycles(now: Date(timeIntervalSince1970: 4000))
        let rows = try store.weeklyLimitHistory().rows.sorted { $0.endsAt < $1.endsAt }
        #expect(rows.first?.totalTokens == 30 && rows.first?.requestCount == 2)
        #expect(rows.first?.amountNanoUSD == nil && rows.first?.knownAmountNanoUSD == 150)
        #expect(rows.last?.totalTokens == 50)
        try store.pool.write { try $0.execute(sql: "UPDATE usage SET amount=50 WHERE source_line=2") }
        try store.saveCompletedWeeklyCycles(now: Date(timeIntervalSince1970: 4000))
        #expect(try store.weeklyLimitHistory().rows.first { $0.endsAt == 1000 }?.amountNanoUSD == 150)
    }

    @Test func upgradeReplaysOldCheckpointsAndPreservesFacts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let thread = "00000000-0000-0000-0000-000000000099"
        let path = sessions.appendingPathComponent("rollout-2026-01-01T00-00-00-\(thread).jsonl")
        let log = """
        {"timestamp":"2026-01-01T00:00:00Z","type":"session_meta","payload":{"id":"\(thread)","creator_account_id":"a"}}
        {"timestamp":"2026-01-01T01:00:00Z","type":"turn_context","payload":{"turn_id":"turn-1"}}
        {"timestamp":"2026-01-01T01:00:10Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":0,"total_tokens":100},"last_token_usage":{"input_tokens":100,"output_tokens":0,"total_tokens":100}},"rate_limits":{"secondary":{"used_percent":40,"window_minutes":10080,"resets_at":1767834000}}}}

        """
        try Data(log.utf8).write(to: path)
        let url = root.appendingPathComponent("usage.sqlite")
        let legacy = try DatabaseQueue(path: url.path)
        try StoreSchema.migrator.migrate(legacy, upTo: "schema.5")
        var state = RolloutParserState(); state.version = 11; state.accountID = "a"
        var fileState = try FileSnapshot(url: path, compressed: false); fileState.completed = true
        let stateJSON = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        let fileJSON = String(decoding: try JSONEncoder().encode(fileState), as: UTF8.self)
        try await legacy.write { db in
            try db.execute(sql: "INSERT INTO scan_files(rollout_id,thread_id,file_name,current_path,parser_state_json,file_state_json) VALUES (?,?,?,?,?,?)",
                arguments: [thread,thread,path.lastPathComponent,path.path,stateJSON,fileJSON])
            try db.execute(sql: "INSERT INTO usage(source_line,rollout_id,source,occurred_at,total_tokens,amount) VALUES (1,'preserved','local',1,7,123)")
            try db.execute(sql: """
                INSERT INTO weekly_limit_cycles(id,limit_id,started_at,scheduled_reset_at,ended_at,reset_kind,last_observed_at)
                VALUES ('old','codex',0,1000,500,'early',400)
                """)
        }
        try legacy.close()
        let store = try UsageStore(databaseURL: url)
        #expect(try store.tableCounts()["usage"] == 1)
        #expect(try store.weeklyLimitHistory().rows.isEmpty)
        let first = try await LocalUsageScanner(store: store).scan(codexHome: root)
        #expect(first.issueCount == 0 && first.scannedFiles == 1)
        let rows = try store.weeklyLimitHistory().rows
        #expect(rows.count == 1 && rows.first?.startedAtInferred == 1767229210 && rows.first?.endsAt == 1767834000)
        let reopened = try UsageStore(databaseURL: url)
        let unchanged = try await LocalUsageScanner(store: reopened).scan(codexHome: root)
        #expect(unchanged.scannedFiles == 0 && unchanged.scannedBytes == 0)
        #expect(try reopened.weeklyLimitHistory().rows == rows)
        #expect(try await reopened.pool.read { try String.fetchOne($0, sql: "SELECT value FROM app_metadata WHERE key='weekly_cycles_rebuild'") } == "complete")
        #expect(try await reopened.pool.read { try Int.fetchOne($0, sql: "SELECT amount FROM usage WHERE rollout_id='preserved'") } == 123)
    }

    @Test func excludedAndNonWeeklyWindowsDoNotCreateCycles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        var inherited = snapshot(200,reset:1000,percent:80); inherited.historyExclusion = "inherited"
        let short = CurrentLimitSnapshot(accountID: "a", observedAt: 200, source: "local", scopeKey: "account:a",
            windows: [.init(limitID: "codex",kind:"primary",usedPercent:20,durationMinutes:300,resetsAt:18200)], sourceJSON:"{}")
        try store.observeWeeklyLimits([inherited,short])
        try store.saveCompletedWeeklyCycles()
        #expect(try store.weeklyLimitHistory().rows.isEmpty)
    }
}
