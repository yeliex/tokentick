import Foundation
import Testing
@testable import TokenTickCore

struct CurrentLimitSessionTests {
    private func snapshot(_ account: String?, time: Double = 1000, source: String = "api") -> CurrentLimitSnapshot {
        CurrentLimitSnapshot(accountID: account, observedAt: time, source: source, scopeKey: "account",
            windows: [CurrentLimitWindow(limitID: "codex", kind: "primary", usedPercent: 10,
                                         durationMinutes: 300, resetsAt: 18_000)], sourceJSON: "{}")
    }

    @Test func apiDisplayNamesArePreservedWithoutChangingBucketIdentity() throws {
        let json = #"{"rateLimitsByLimitId":{"codex_bengalfox":{"limitName":"Codex Spark","primary":{"usedPercent":0,"windowDurationMins":300,"resetsAt":18000}}}}"#
        let snapshot = try CurrentLimitSnapshot.parse(Data(json.utf8), accountID: "a", observedAt: 1000, source: "api", scopeKey: "a")
        #expect(snapshot.windows.first?.displayName == "Codex Spark")
        #expect(snapshot.windows.first?.limitID == "codex_bengalfox")
        let legacy = #"{"limitID":"codex","kind":"primary","usedPercent":10,"durationMinutes":300,"resetsAt":18000}"#
        #expect(try JSONDecoder().decode(CurrentLimitWindow.self, from: Data(legacy.utf8)).displayName == nil)
    }

    @Test func optionalPlanResetCountAndCreditsRemainAccountSnapshotMetadata() throws {
        let json = #"{"rateLimitResetCredits":{"availableCount":2},"rateLimitsByLimitId":{"codex":{"planType":"pro","credits":{"balance":"12.50","unlimited":false,"hasCredits":true}}}}"#
        let value = try CurrentLimitSnapshot.parse(Data(json.utf8), accountID: "a", observedAt: 1000, source: "api", scopeKey: "a")
        #expect(value.planType == "pro" && value.availableResets == 2 && value.creditsBalance == "12.50")
        let missing = try CurrentLimitSnapshot.parse(Data(#"{"rateLimits":{}}"#.utf8), accountID: "b", observedAt: 1000, source: "api", scopeKey: "b")
        #expect(missing.planType == nil && missing.availableResets == nil && missing.creditsBalance == nil)
    }

    @Test func resetExpiryUsesOnlyAvailableUnexpiredCodexCredits() throws {
        let json = #"{"rateLimits":{},"rateLimitResetCredits":{"availableCount":5,"credits":[{"status":"available","resetType":"codexRateLimits","expiresAt":5000},{"status":"available","resetType":"codexRateLimits","expiresAt":3000},{"status":"available","resetType":"codexRateLimits","expiresAt":null},{"status":"redeemed","resetType":"codexRateLimits","expiresAt":2000},{"status":"available","resetType":"unknown","expiresAt":1500},{"status":"available","resetType":"codexRateLimits","expiresAt":500}]}}"#
        let value = try CurrentLimitSnapshot.parse(Data(json.utf8), accountID: "a", observedAt: 1000, source: "api", scopeKey: "a")
        #expect(value.availableResets == 5 && value.resetCreditExpirations == [3000, 5000, nil])
        let missing = try CurrentLimitSnapshot.parse(Data(#"{"rateLimits":{},"rateLimitResetCredits":{"availableCount":2,"credits":null}}"#.utf8), accountID: "a", observedAt: 1000, source: "api", scopeKey: "a")
        #expect(missing.availableResets == 2 && missing.resetCreditExpirations == nil)
    }

    @Test func invalidationRejectsOldRequestsEvenWhenAccountSwitchesBack() {
        var state = CurrentLimitSession()
        let request = state.generation
        let first = state.acceptAPI(snapshot("a"), generation: request, now: 1000)
        #expect(first)
        state.invalidate()
        #expect(state.snapshot == nil && state.forecasts.accountID == nil)
        let switched = state.acceptAPI(snapshot("b"), generation: state.generation, now: 1000)
        #expect(switched)
        state.invalidate()
        let old = state.acceptAPI(snapshot("a"), generation: request, now: 1000)
        #expect(!old)
        #expect(state.snapshot == nil)
    }

    @Test func localOrUnconfirmedAccountsCannotBecomeCurrentAndFailuresClearSnapshots() {
        var state = CurrentLimitSession()
        for invalid in [snapshot(nil), snapshot(""), snapshot("a", source: "local"),
                        snapshot("a", time: 2001), snapshot("a", time: 100)] {
            let valid = state.acceptAPI(snapshot("a", time: 1500), generation: state.generation, now: 2000)
            #expect(valid)
            let accepted = state.acceptAPI(invalid, generation: state.generation, now: 2000)
            #expect(!accepted)
            #expect(state.snapshot == nil)
        }
        let valid = state.acceptAPI(snapshot("a"), generation: state.generation, now: 1000)
        #expect(valid)
        let failure = state.acceptAPI(nil, generation: state.generation, now: 1000)
        #expect(!failure)
        #expect(state.snapshot == nil && state.forecasts.accountID == nil)
    }

    @Test func newerLogMergesWindowsAndPreservesAccountMetadata() {
        var state = CurrentLimitSession()
        var api = snapshot("a")
        api.planType = "pro"; api.availableResets = 2; api.creditsBalance = "12.50"
        api.resetCreditExpirations = [3000, 5000]
        state.acceptAPI(api, generation: 0, now: 1000)
        let accepted1 = state.acceptLog(snapshot(nil, time: 1100, source: "local"), generation: 0, now: 1101)
        #expect(accepted1)
        #expect(state.snapshot?.source == "local" && state.snapshot?.accountID == "a")
        #expect(state.snapshot?.planType == "pro" && state.snapshot?.availableResets == 2)
        #expect(state.snapshot?.creditsBalance == "12.50")
        #expect(state.snapshot?.resetCreditExpirations == [3000, 5000])
        let accepted2 = state.acceptLog(snapshot(nil, time: 1100, source: "local"), generation: 0, now: 1101)
        #expect(!accepted2)
        let accepted3 = state.acceptAPI(snapshot("a", time: 1050), generation: 0, now: 1101)
        #expect(!accepted3)
    }

    @Test func logsRequireFreshMatchingWindowsAndCurrentLoginGeneration() {
        var state = CurrentLimitSession()
        let accepted4 = state.acceptLog(snapshot(nil, time: 1100, source: "local"), generation: 0, now: 1100)
        #expect(!accepted4)
        state.acceptAPI(snapshot("a"), generation: 0, now: 1000)
        let accepted5 = state.acceptLog(snapshot("b", time: 1100, source: "local"), generation: 0, now: 1100)
        #expect(!accepted5)
        let accepted6 = state.acceptLog(snapshot(nil, time: 1100, source: "local"), generation: 0, now: 1401)
        #expect(!accepted6)
        let accepted7 = state.acceptLog(snapshot(nil, time: 1101, source: "local"), generation: 0, now: 1100)
        #expect(!accepted7)
        let accepted8 = state.acceptLog(snapshot(nil, time: 2800, source: "local"), generation: 0, now: 2800)
        #expect(!accepted8)
        var inherited = snapshot(nil, time: 1100, source: "local")
        inherited.historyExclusion = "inherited"
        let accepted9 = state.acceptLog(inherited, generation: 0, now: 1100)
        #expect(!accepted9)
        for (percent, reset) in [(5.0, Int64(18000)), (20.0, Int64(19000))] {
            let log = CurrentLimitSnapshot(accountID: nil, observedAt: 1100, source: "local", scopeKey: "thread:a",
                windows: [.init(limitID: "codex", kind: "primary", usedPercent: percent,
                                durationMinutes: 300, resetsAt: reset)], sourceJSON: "{}")
            let accepted10 = state.acceptLog(log, generation: 0, now: 1100)
            #expect(!accepted10)
        }
        state.invalidate()
        state.acceptAPI(snapshot("a"), generation: state.generation, now: 1000)
        let accepted11 = state.acceptLog(snapshot(nil, time: 1100, source: "local"), generation: 0, now: 1100)
        #expect(!accepted11)
    }


    @Test func partialLogUpdatesOnlyItsWindow() {
        var state = CurrentLimitSession()
        let main = CurrentLimitWindow(limitID: "codex", kind: "primary", usedPercent: 10,
                                      durationMinutes: 300, resetsAt: 18000)
        let extra = CurrentLimitWindow(limitID: "spark", kind: "primary", usedPercent: 30,
                                       durationMinutes: 300, resetsAt: 18000, displayName: "Codex Spark")
        let api = CurrentLimitSnapshot(accountID: "a", observedAt: 1000, source: "api", scopeKey: "account:a",
                                       windows: [main, extra], sourceJSON: "{}")
        state.acceptAPI(api, generation: 0, now: 1000)
        let updated = CurrentLimitWindow(limitID: "codex", kind: "primary", usedPercent: 20,
                                         durationMinutes: 300, resetsAt: 18000)
        let log = CurrentLimitSnapshot(accountID: nil, observedAt: 1100, source: "local", scopeKey: "thread:x",
                                       windows: [updated], sourceJSON: "{}")
        let accepted = state.acceptLog(log, generation: 0, now: 1100)
        #expect(accepted)
        #expect(state.snapshot?.windows.count == 2)
        #expect(state.snapshot?.windows.first?.usedPercent == 20)
        #expect(state.snapshot?.windows.last?.usedPercent == 30)
        #expect(state.snapshot?.windows.last?.displayName == "Codex Spark")
    }

}
