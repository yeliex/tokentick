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
        #expect(history.forecast(for: snapshot(1500, 25).windows[0], now: 1500).state == .insufficient)
        history.confirmAccount(nil)
        history.record(snapshot(1800, 30, account: nil), now: 1800)
        #expect(history.forecast(for: snapshot(1800, 30).windows[0], now: 1800).sampleCount == 0)
    }

    @Test func handlesIdleExhaustedStaleAndInsufficientSamples() {
        var history = LimitForecastHistory()
        history.confirmAccount("a")
        history.record(snapshot(600, 10), now: 600)
        #expect(history.forecast(for: snapshot(600, 10).windows[0], now: 600).state == .insufficient)
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
            #expect(history.forecast(for: latest.windows[0], now: latest.observedAt).state == .insufficient)
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
        #expect(history.forecast(for: snapshot(1500, 5, bucket: "spark").windows[0], now: 1500).state == .insufficient)
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
