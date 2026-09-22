import Foundation
import Testing
@testable import TokenTickCore

struct LimitResetDetectorTests {
    private func snapshot(time: Double, reset: Int64 = 18_000, used: Double = 50,
                          account: String? = "a", source: String = "api", duration: Int64 = 300,
                          plan: String? = "pro") -> CurrentLimitSnapshot {
        var value = CurrentLimitSnapshot(accountID: account, observedAt: time, source: source, scopeKey: "account",
            windows: [CurrentLimitWindow(limitID: "codex", kind: "primary", usedPercent: used,
                                         durationMinutes: duration, resetsAt: reset)], sourceJSON: "{}")
        value.planType = plan
        return value
    }

    @Test func naturalResetAndDuplicate() {
        var detector = LimitResetDetector()
        #expect(detector.observe(snapshot(time: 17_990), now: 17_990).isEmpty)
        let reset = snapshot(time: 18_001, reset: 36_000, used: 2)
        #expect(detector.observe(reset, now: 18_001).count == 1)
        #expect(detector.observe(reset, now: 18_002).isEmpty)
        #expect(detector.observe(snapshot(time: 18_100, reset: 36_000, used: 3), now: 18_100).isEmpty)
    }

    @Test func earlyWeeklyReset() {
        var detector = LimitResetDetector()
        #expect(detector.observe(snapshot(time: 1000, reset: 604_800, duration: 10_080), now: 1000).isEmpty)
        let events = detector.observe(snapshot(time: 1100, reset: 605_800, used: 1, duration: 10_080), now: 1100)
        #expect(events.first?.durationMinutes == 10_080)
    }

    @Test func startupAccountAndPlanChangesAreBaselines() {
        var detector = LimitResetDetector()
        _ = detector.observe(snapshot(time: 1000), now: 1000)
        #expect(detector.observe(snapshot(time: 2000, reset: 19_000, used: 0, account: "b"), now: 2000).isEmpty)
        #expect(detector.observe(snapshot(time: 3000, reset: 20_000, used: 0, account: "a"), now: 3000).isEmpty)
        #expect(detector.observe(snapshot(time: 4000, reset: 21_000, used: 0, plan: "plus"), now: 4000).isEmpty)
    }

    @Test func logsMissingIdentityAndStaleDataCannotTrigger() {
        var detector = LimitResetDetector()
        _ = detector.observe(snapshot(time: 1000), now: 1000)
        #expect(detector.observe(snapshot(time: 1100, reset: 19_000, used: 0, source: "local"), now: 1100).isEmpty)
        #expect(detector.observe(snapshot(time: 1100, reset: 19_000, used: 0, account: nil), now: 1100).isEmpty)
        #expect(detector.observe(snapshot(time: 1100, reset: 19_000, used: 0), now: 3000).isEmpty)
        #expect(detector.observe(snapshot(time: 3100, reset: 20_000, used: 0), now: 3000).isEmpty)
        #expect(detector.observe(snapshot(time: 1200, reset: 19_000, used: 0), now: 1200).count == 1)
    }

    @Test func timestampJitterIdleAndPercentageCorrectionsDoNotReset() {
        var detector = LimitResetDetector()
        _ = detector.observe(snapshot(time: 1000), now: 1000)
        #expect(detector.observe(snapshot(time: 1100, reset: 18_040, used: 0), now: 1100).isEmpty)
        #expect(detector.observe(snapshot(time: 1200, reset: 18_080, used: 0), now: 1200).isEmpty)
        #expect(detector.observe(snapshot(time: 1300, reset: 18_500, used: 0), now: 1300).isEmpty)
        #expect(detector.observe(snapshot(time: 1400, reset: 18_500, used: 30), now: 1400).isEmpty)
        #expect(detector.observe(snapshot(time: 1500, reset: 18_500, used: 0), now: 1500).isEmpty)
    }

    @Test func regressedBoundaryCannotRearmDuplicate() {
        var detector = LimitResetDetector()
        _ = detector.observe(snapshot(time: 1000), now: 1000)
        #expect(detector.observe(snapshot(time: 2000, reset: 19_000, used: 0), now: 2000).count == 1)
        #expect(detector.observe(snapshot(time: 2100, reset: 18_000, used: 50), now: 2100).isEmpty)
        #expect(detector.observe(snapshot(time: 2200, reset: 19_000, used: 0), now: 2200).isEmpty)
    }

    @Test func missingWindowsReestablishBaseline() {
        var detector = LimitResetDetector()
        _ = detector.observe(snapshot(time: 1000), now: 1000)
        let empty = CurrentLimitSnapshot(accountID: "a", observedAt: 1100, source: "api", scopeKey: "account",
                                         windows: [], sourceJSON: "{}")
        _ = detector.observe(empty, now: 1100)
        #expect(detector.observe(snapshot(time: 1200, reset: 19_000, used: 0), now: 1200).isEmpty)
    }
}
