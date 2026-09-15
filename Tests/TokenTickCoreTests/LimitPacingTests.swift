import Testing
@testable import TokenTickCore

struct LimitPacingTests {
    private let weekly = CurrentLimitWindow(limitID: "codex", kind: "secondary", usedPercent: 20,
                                           durationMinutes: 10080, resetsAt: 604800)

    @Test func workingDaysOnlyChangeTicks() {
        #expect(weekly.usageTicks(workingDays: 4) == [25, 50, 75, 80])
        #expect(weekly.usageTicks(workingDays: 5) == [20, 40, 50, 60, 80])
        #expect(weekly.usageTicks(workingDays: 7).contains(100.0 / 7))
        #expect(weekly.expectedUsedPercent(now: 302400) == 50)
        #expect(weekly.expectedUsedPercent(now: 0) == 0)
        #expect(weekly.expectedUsedPercent(now: -1) == nil)
        #expect(weekly.expectedUsedPercent(now: 604800) == nil)
    }

    @Test func shortWindowHasTimeMarkerWithoutDailyTicks() {
        let window = CurrentLimitWindow(limitID: "codex", kind: "primary", usedPercent: 20,
                                        durationMinutes: 300, resetsAt: 18000)
        #expect(window.usageTicks(workingDays: 4).isEmpty)
        #expect(window.expectedUsedPercent(now: 9000) == 50)
        #expect(window.expectedUsedPercent(now: .nan) == nil)
    }
}
