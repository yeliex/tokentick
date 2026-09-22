import Foundation

/// Compares fresh API observations only. Startup and account changes establish a baseline, never a reset.
public struct LimitResetDetector: Sendable {
    public struct Event: Equatable, Sendable {
        public let durationMinutes: Int64
        public let usedPercent: Double
        public let resetsAt: Int64
    }

    private var accountID: String?
    private var plan: String?
    private var observedAt: Double?
    private var windows: [String: CurrentLimitWindow] = [:]

    public init() {}

    public mutating func observe(_ snapshot: CurrentLimitSnapshot, now: Double) -> [Event] {
        guard snapshot.source == "api", let account = snapshot.accountID, !account.isEmpty,
              snapshot.observedAt.isFinite, snapshot.observedAt <= now,
              now - snapshot.observedAt <= 900 else { return [] }
        if account != accountID || snapshot.planType != plan {
            self = Self()
            accountID = account
            plan = snapshot.planType
        }
        if let observedAt, snapshot.observedAt <= observedAt { return [] }
        observedAt = snapshot.observedAt
        var next: [String: CurrentLimitWindow] = [:]
        var events: [Event] = []
        for window in snapshot.windows {
            guard window.limitID == "codex", let duration = window.durationMinutes,
                  [300, 10_080].contains(duration), let reset = window.resetsAt,
                  Double(reset) > now, Double(reset) - snapshot.observedAt <= Double(duration) * 60 + 60,
                  window.usedPercent.isFinite, (0...100).contains(window.usedPercent) else { continue }
            next[window.id] = window
            guard let previous = windows[window.id], previous.durationMinutes == duration,
                  let oldReset = previous.resetsAt else { continue }
            let delta = Double(reset) - Double(oldReset)
            // Keep a fixed boundary anchor so small timestamp corrections cannot accumulate into a reset.
            if delta <= 60 {
                next[window.id] = CurrentLimitWindow(limitID: window.limitID, kind: window.kind,
                    usedPercent: delta < -60 ? previous.usedPercent : window.usedPercent,
                    durationMinutes: duration, resetsAt: oldReset)
                continue
            }
            let natural = snapshot.observedAt >= Double(oldReset)
            let early = previous.usedPercent > 1 && window.usedPercent <= 5
                && window.usedPercent < previous.usedPercent
            if previous.usedPercent > 0 && (natural || early) {
                events.append(Event(durationMinutes: duration, usedPercent: window.usedPercent, resetsAt: reset))
            }
        }
        windows = next
        return events
    }
}
