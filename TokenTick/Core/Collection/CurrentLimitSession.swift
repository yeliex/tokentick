import Foundation

/// Invalidate on login changes; tag async results with their starting generation even when switching back to the same account.
public struct CurrentLimitSession: Sendable {
    public private(set) var generation = 0
    public private(set) var snapshot: CurrentLimitSnapshot?
    private var apiObservedAt: Double?
    public private(set) var forecasts = LimitForecastHistory()

    public init() {}

    public mutating func invalidate() {
        generation += 1
        snapshot = nil
        apiObservedAt = nil
        forecasts.confirmAccount(nil)
    }

    @discardableResult
    public mutating func restoreCached(_ value: CurrentLimitSnapshot, now: Double) -> Bool {
        guard snapshot == nil, value.source == "api", let account = value.accountID, !account.isEmpty,
              value.observedAt.isFinite, value.observedAt <= now,
              value.windows.allSatisfy({ $0.usedPercent.isFinite && $0.usedPercent >= 0 }) else { return false }
        snapshot = value
        // Cached display data is not a fresh API confirmation or a forecast sample.
        apiObservedAt = nil
        forecasts.confirmAccount(nil)
        return true
    }

    @discardableResult
    public mutating func acceptAPI(_ value: CurrentLimitSnapshot?, generation: Int, now: Double) -> Bool {
        guard generation == self.generation else { return false }
        guard let value, value.source == "api", let account = value.accountID, !account.isEmpty,
              value.observedAt.isFinite, value.observedAt <= now, now - value.observedAt <= 900 else {
            snapshot = nil
            apiObservedAt = nil
            forecasts.confirmAccount(nil)
            return false
        }
        if let snapshot, value.observedAt < snapshot.observedAt { return false }
        forecasts.confirmAccount(account)
        snapshot = value
        apiObservedAt = value.observedAt
        forecasts.record(value, now: now)
        return true
    }

    /// Infer accountless log ownership only within the API-confirmed login session; never backfill historical accounts.
    @discardableResult
    public mutating func acceptLog(_ value: CurrentLimitSnapshot?, generation: Int, now: Double) -> Bool {
        guard generation == self.generation, let value, value.source == "local",
              value.historyExclusion == nil, let current = snapshot, let apiObservedAt,
              now - apiObservedAt < 1800, value.observedAt.isFinite,
              value.observedAt > current.observedAt, value.observedAt <= now,
              now - value.observedAt <= 300,
              value.accountID == nil || value.accountID == current.accountID,
              !value.windows.isEmpty else { return false }
        // Leave new windows, early resets, and duration changes to the API to avoid accepting stale or cross-account logs.
        guard value.windows.allSatisfy({ window in
            guard let previous = current.windows.first(where: { $0.id == window.id }),
                  let duration = window.durationMinutes, duration > 0,
                  duration == previous.durationMinutes, let reset = window.resetsAt,
                  let previousReset = previous.resetsAt, Double(reset) > now else { return false }
            return abs(Double(reset) - Double(previousReset)) <= 60
                && window.usedPercent.isFinite && window.usedPercent >= previous.usedPercent
        }) else { return false }
        let windows = current.windows.map { previous in
            guard var updated = value.windows.first(where: { $0.id == previous.id }) else { return previous }
            updated.displayName = updated.displayName ?? previous.displayName
            return updated
        }
        var merged = CurrentLimitSnapshot(accountID: current.accountID, observedAt: value.observedAt,
            source: "local", scopeKey: current.scopeKey, windows: windows, sourceJSON: value.sourceJSON)
        merged.planType = value.planType ?? current.planType
        merged.availableResets = current.availableResets
        merged.resetCreditExpirations = current.resetCreditExpirations
        merged.creditsBalance = value.creditsBalance ?? current.creditsBalance
        merged.unlimitedCredits = value.unlimitedCredits ?? current.unlimitedCredits
        merged.fileName = value.fileName
        merged.line = value.line
        merged.turnID = value.turnID
        snapshot = merged
        // Sample only windows actually updated by this log, not retained additional limits.
        let observation = CurrentLimitSnapshot(accountID: current.accountID, observedAt: value.observedAt,
            source: "local", scopeKey: current.scopeKey, windows: value.windows, sourceJSON: value.sourceJSON)
        forecasts.record(observation, now: now)
        return true
    }

}
