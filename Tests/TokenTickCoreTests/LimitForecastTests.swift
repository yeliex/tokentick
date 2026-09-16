import Testing
@testable import TokenTickCore

struct LimitForecastTests {
    private func snapshot(_ time: Double, _ percent: Double, account: String? = "a",
                          reset: Int64 = 18_000, duration: Int64 = 300,
                          bucket: String = "codex") -> CurrentLimitSnapshot {
        CurrentLimitSnapshot(accountID: account, observedAt: time, source: "api", scopeKey: "account",
            windows: [CurrentLimitWindow(limitID: bucket, kind: "primary", usedPercent: percent,
                                         durationMinutes: duration, resetsAt: reset)], sourceJSON: "{}")
    }

    @Test func bootstrapsFromCycleAverageThenUsesRecentRate() throws {
        var history = LimitForecastHistory()
        history.confirmAccount("a")
        history.record(snapshot(9000, 25), now: 9000)
        let initial = history.forecast(for: snapshot(9000, 25).windows[0], now: 9000)
        #expect(initial.state == .estimated)
        #expect(initial.sampleCount == 1)
        #expect(initial.percentagePointsPerHour == 10)
        #expect(initial.exhaustsAt == 36_000)
        #expect(initial.remainingAtReset == 50)
        // Advancing the clock without an observation must not dilute measured consumption.
        #expect(history.forecast(for: snapshot(9000, 25).windows[0], now: 9300) == initial)
        history.record(snapshot(9300, 30), now: 9300)
        let blended = history.forecast(for: snapshot(9300, 30).windows[0], now: 9300)
        #expect(abs(try #require(blended.percentagePointsPerHour) - 35.8064516129) < 0.00001)
        history.record(snapshot(9600, 35), now: 9600)
        let recent = history.forecast(for: snapshot(9600, 35).windows[0], now: 9600)
        #expect(recent.percentagePointsPerHour == 60)
        #expect(recent.exhaustsAt == 13_500)
        #expect(recent.remainingAtReset == 0)
    }

    @Test func shortIntervalsDampenRoundingAndTwoSamplesCanEstablishRate() throws {
        var history = LimitForecastHistory()
        history.confirmAccount("a")
        history.record(snapshot(9000, 25), now: 9000)
        history.record(snapshot(9001, 26), now: 9001)
        let rounded = history.forecast(for: snapshot(9001, 26).windows[0], now: 9001)
        let rate = try #require(rounded.percentagePointsPerHour)
        #expect(rate > 10 && rate < 17)

        var twoPoints = LimitForecastHistory()
        twoPoints.confirmAccount("a")
        twoPoints.record(snapshot(9000, 25), now: 9000)
        twoPoints.record(snapshot(9600, 35), now: 9600)
        #expect(twoPoints.forecast(for: snapshot(9600, 35).windows[0], now: 9600).percentagePointsPerHour == 60)
    }

    @Test func unchangedSamplesGraduallyReduceRateWithoutInventingConsumption() throws {
        var history = LimitForecastHistory()
        history.confirmAccount("a")
        history.record(snapshot(9000, 25), now: 9000)
        history.record(snapshot(9300, 25), now: 9300)
        let interim = history.forecast(for: snapshot(9300, 25).windows[0], now: 9300)
        let rate = try #require(interim.percentagePointsPerHour)
        #expect(rate > 0 && rate < 5)
        history.record(snapshot(9600, 25), now: 9600)
        #expect(history.forecast(for: snapshot(9600, 25).windows[0], now: 9600).state == .idle)
    }

    @Test func bootstrapRequiresLiveObservationAndPositiveElapsedTime() {
        var history = LimitForecastHistory()
        let window = snapshot(0, 10).windows[0]
        #expect(history.forecast(for: window, now: 600).state == .insufficient)
        history.confirmAccount("a")
        history.record(snapshot(0, 10), now: 0)
        #expect(history.forecast(for: window, now: 0).state == .insufficient)
        #expect(history.forecast(for: window, now: 901).state == .stale)
        history.record(snapshot(1200, 0), now: 1200)
        let idle = history.forecast(for: snapshot(1200, 0).windows[0], now: 1200)
        #expect(idle.state == .idle && idle.exhaustsAt == nil)
    }

    @Test func predictsExhaustionAndResetHeadroomFromObservedPercentages() throws {
        var history = LimitForecastHistory()
        history.confirmAccount("a")
        for (time, percent) in [(600.0, 10.0), (900, 15), (1200, 20)] {
            history.record(snapshot(time, percent), now: time)
        }
        let value = history.forecast(for: snapshot(1200, 20).windows[0], now: 1200)
        #expect(value.state == .estimated)
        #expect(value.percentagePointsPerHour == 60)
        #expect(value.exhaustsAt == 6000)
        #expect(value.remainingAtReset == 0)
        #expect(abs(try #require(value.progressDifference) - 13.3333333333) < 0.00001)

        var slower = LimitForecastHistory()
        slower.confirmAccount("a")
        for (time, percent) in [(600.0, 10.0), (900, 10.5), (1200, 11)] {
            slower.record(snapshot(time, percent), now: time)
        }
        let headroom = slower.forecast(for: snapshot(1200, 11).windows[0], now: 1200)
        #expect(headroom.remainingAtReset == 61)
    }

    @Test func accountChangesRejectOldResponsesAndNeverRestoreOldHistory() {
        var history = LimitForecastHistory()
        history.confirmAccount("a")
        history.record(snapshot(600, 10), now: 600)
        history.record(snapshot(900, 15), now: 900)
        history.confirmAccount("b")
        history.record(snapshot(1200, 20), now: 1200)
        #expect(history.forecast(for: snapshot(1200, 20).windows[0], now: 1200).sampleCount == 0)
        history.confirmAccount("a")
        history.record(snapshot(1500, 25), now: 1500)
        #expect(history.forecast(for: snapshot(1500, 25).windows[0], now: 1500).state == .estimated)
        history.confirmAccount(nil)
        history.record(snapshot(1800, 30, account: nil), now: 1800)
        #expect(history.forecast(for: snapshot(1800, 30).windows[0], now: 1800).sampleCount == 0)
    }

    @Test func handlesIdleExhaustedStaleAndInsufficientSamples() {
        var history = LimitForecastHistory()
        history.confirmAccount("a")
        history.record(snapshot(600, 10), now: 600)
        #expect(history.forecast(for: snapshot(600, 10).windows[0], now: 600).state == .estimated)
        history.record(snapshot(900, 10), now: 900)
        history.record(snapshot(1200, 10), now: 1200)
        let idle = history.forecast(for: snapshot(1200, 10).windows[0], now: 1200)
        #expect(idle.state == .idle && idle.exhaustsAt == nil && idle.remainingAtReset == nil)
        #expect(history.forecast(for: snapshot(1200, 10).windows[0], now: 2101).state == .stale)
        history.record(snapshot(1500, 100), now: 1500)
        #expect(history.forecast(for: snapshot(1500, 100).windows[0], now: 1500).state == .exhausted)
        #expect(history.forecast(for: snapshot(1500, 100).windows[0], now: 18_000).state == .invalidBoundary)
    }

    @Test func resetsHistoryAcrossRecoveryBoundaryAndObservationGaps() {
        for kind in ["reset", "decrease", "gap", "duration"] {
            var history = LimitForecastHistory()
            history.confirmAccount("a")
            history.record(snapshot(600, 10), now: 600)
            history.record(snapshot(900, 15), now: 900)
            let latest = snapshot(kind == "gap" ? 2000 : 1200, kind == "decrease" ? 1 : 20,
                                  reset: kind == "reset" ? 19_000 : 18_000,
                                  duration: kind == "duration" ? 10080 : 300)
            history.record(latest, now: latest.observedAt)
            #expect(history.forecast(for: latest.windows[0], now: latest.observedAt).state == .estimated)
        }
    }

    @Test func rejectsReplayFutureAndStaleInputAndDoesNotMixBuckets() {
        var history = LimitForecastHistory()
        history.confirmAccount("a")
        history.record(snapshot(600, 10), now: 600)
        history.record(snapshot(900, 15), now: 900)
        history.record(snapshot(600, 99), now: 900)
        history.record(snapshot(1200, 99), now: 900)
        history.record(snapshot(950, 99), now: 3000)
        history.record(snapshot(1200, 20), now: 1200)
        #expect(history.forecast(for: snapshot(1200, 20).windows[0], now: 1200).exhaustsAt == 6000)
        history.record(snapshot(1500, 5, bucket: "spark"), now: 1500)
        #expect(history.forecast(for: snapshot(1500, 5, bucket: "spark").windows[0], now: 1500).state == .estimated)
        #expect(history.forecast(for: snapshot(1500, 20).windows[0], now: 1500).sampleCount == 0)
    }

    @Test func resetToleranceUsesFixedAnchorAndStorageIsBounded() {
        var history = LimitForecastHistory()
        history.confirmAccount("a")
        history.record(snapshot(600, 10), now: 600)
        history.record(snapshot(900, 15, reset: 18_050), now: 900)
        let shifted = snapshot(1200, 20, reset: 18_100)
        history.record(shifted, now: 1200)
        #expect(history.forecast(for: shifted.windows[0], now: 1200).sampleCount == 1)
        for index in 1...1000 {
            let value = snapshot(1200 + Double(index), 20, reset: 18_100)
            history.record(value, now: value.observedAt)
        }
        #expect(history.forecast(for: shifted.windows[0], now: 2200).sampleCount == 360)
    }
}
