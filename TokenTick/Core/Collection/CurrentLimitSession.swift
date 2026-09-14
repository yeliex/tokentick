import Foundation

/// 登录环境变化时立即失效；异步结果必须携带请求开始时的代次，防止切回同一账号后接收旧结果。
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

    /// 日志没有账号身份；仅在本次登录环境内，用 API 已确认的窗口边界推断归属，不写回历史账号。
    @discardableResult
    public mutating func acceptLog(_ value: CurrentLimitSnapshot?, generation: Int, now: Double) -> Bool {
        guard generation == self.generation, let value, value.source == "local",
              value.historyExclusion == nil, let current = snapshot, let apiObservedAt,
              now - apiObservedAt < 1800, value.observedAt.isFinite,
              value.observedAt > current.observedAt, value.observedAt <= now,
              now - value.observedAt <= 300,
              value.accountID == nil || value.accountID == current.accountID,
              !value.windows.isEmpty else { return false }
        // 未确认的新窗口、提前重置或周期变化交给 API；避免跨账号或旧日志覆盖当前额度。
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
        // 仅采样本次日志实际更新的窗口，不能把保留的扩展额度当作新观测。
        let observation = CurrentLimitSnapshot(accountID: current.accountID, observedAt: value.observedAt,
            source: "local", scopeKey: current.scopeKey, windows: value.windows, sourceJSON: value.sourceJSON)
        forecasts.record(observation, now: now)
        return true
    }

}
