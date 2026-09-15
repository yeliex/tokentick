import Foundation

public struct LimitForecast: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case insufficient, stale, invalidBoundary, idle, exhausted, estimated
    }

    public let state: State
    public let observedAt: Double?
    public let sampleCount: Int
    public let sampledSeconds: Double
    public let percentagePointsPerHour: Double?
    public let exhaustsAt: Double?
    public let remainingAtReset: Double?
    public let progressDifference: Double?
}

/// Keep recent consecutive observations for a confirmed account; historical replay is not live consumption.
public struct LimitForecastHistory: Sendable {
    private struct Sample: Sendable {
        let time: Double
        let percent: Double
    }
    private struct Series: Sendable {
        let reset: Int64
        let duration: Int64
        var samples: [Sample]
    }

    public private(set) var accountID: String?
    private var series: [String: Series] = [:]
    private var lastObservedAt: Double?
    private static let freshness: Double = 15 * 60
    private static let horizon: Double = 6 * 60 * 60

    public init() {}

    public mutating func confirmAccount(_ accountID: String?) {
        let accountID = accountID.flatMap { $0.isEmpty ? nil : $0 }
        guard self.accountID != accountID else { return }
        self.accountID = accountID
        series = [:]
        lastObservedAt = nil
    }

    public mutating func record(_ snapshot: CurrentLimitSnapshot, now: Double) {
        guard let accountID, snapshot.accountID == accountID,
              now.isFinite, snapshot.observedAt.isFinite,
              snapshot.observedAt <= now, now - snapshot.observedAt <= Self.freshness,
              snapshot.observedAt > (lastObservedAt ?? -.infinity) else { return }
        lastObservedAt = snapshot.observedAt
        let identifiers = Set(snapshot.windows.map(\.id))
        if snapshot.source == "api" { series = series.filter { identifiers.contains($0.key) } }
        for window in snapshot.windows {
            guard let reset = window.resetsAt, let duration = window.durationMinutes,
                  duration > 0, window.usedPercent.isFinite, window.usedPercent >= 0,
                  Double(reset) > snapshot.observedAt,
                  Double(reset) - Double(duration) * 60 <= snapshot.observedAt + 60 else {
                series[window.id] = nil
                continue
            }
            let sample = Sample(time: snapshot.observedAt, percent: window.usedPercent)
            if var existing = series[window.id], existing.duration == duration,
               abs(Double(existing.reset) - Double(reset)) <= 60,
               let last = existing.samples.last,
               sample.time - last.time <= Self.freshness, sample.percent >= last.percent {
                existing.samples.removeAll { sample.time - $0.time > Self.horizon }
                existing.samples.append(sample)
                // Bound in-memory history even during frequent synchronization.
                existing.samples = Array(existing.samples.suffix(360))
                series[window.id] = existing
            } else {
                series[window.id] = Series(reset: reset, duration: duration, samples: [sample])
            }
        }
    }

    public func forecast(for window: CurrentLimitWindow, now: Double) -> LimitForecast {
        guard now.isFinite, let reset = window.resetsAt, let duration = window.durationMinutes,
              duration > 0, Double(reset) > now,
              Double(reset) - Double(duration) * 60 <= now + 60 else {
            return result(.invalidBoundary)
        }
        guard let series = series[window.id], series.duration == duration,
              abs(Double(series.reset) - Double(reset)) <= 60,
              let first = series.samples.first, let last = series.samples.last else {
            return result(.insufficient)
        }
        let span = last.time - first.time
        guard now >= last.time, now - last.time <= Self.freshness else {
            return result(.stale, observedAt: last.time, count: series.samples.count, span: span)
        }
        // Compare pacing at the observation time, not across unobserved elapsed time.
        let elapsed = max(0, last.time - (Double(reset) - Double(duration) * 60))
        let progress = last.percent - min(100, elapsed / (Double(duration) * 60) * 100)
        if last.percent >= 100 {
            return result(.exhausted, observedAt: last.time, count: series.samples.count, span: span,
                          exhaustsAt: last.time, remaining: 0, progress: progress)
        }
        guard series.samples.count >= 3, span >= 600 else {
            return result(.insufficient, observedAt: last.time, count: series.samples.count, span: span, progress: progress)
        }
        let rate = (last.percent - first.percent) / span
        guard rate > 0 else {
            return result(.idle, observedAt: last.time, count: series.samples.count, span: span,
                          rate: 0, progress: progress)
        }
        let exhausted = last.time + (100 - last.percent) / rate
        let remaining = max(0, 100 - last.percent - rate * (Double(reset) - last.time))
        return result(.estimated, observedAt: last.time, count: series.samples.count, span: span,
                      rate: rate * 3600, exhaustsAt: exhausted, remaining: remaining, progress: progress)
    }

    private func result(_ state: LimitForecast.State, observedAt: Double? = nil, count: Int = 0,
                        span: Double = 0, rate: Double? = nil, exhaustsAt: Double? = nil,
                        remaining: Double? = nil, progress: Double? = nil) -> LimitForecast {
        LimitForecast(state: state, observedAt: observedAt, sampleCount: count, sampledSeconds: span,
                      percentagePointsPerHour: rate, exhaustsAt: exhaustsAt,
                      remainingAtReset: remaining, progressDifference: progress)
    }
}
