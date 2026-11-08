import Foundation

/// Schedule triggers only; scans, prices, and API calls use the shared synchronization entry point.
public struct AutomaticSyncSchedule: Sendable {
    private var remoteDue: Date
    private var remoteDeadline: Date
    private var localAllowed: Date
    private var changedAt: Date?
    private var lastLocalStart: Date?
    private var isActive = true
    private var quietUntil = Date.distantPast
    private var watcherAvailable = true

    public init(now: Date = Date()) {
        changedAt = now; remoteDue = now; remoteDeadline = now; localAllowed = now
    }

    public var nextCheck: Date {
        min(remoteDue, max(localAllowed, changedAt ?? .distantFuture))
    }

    public mutating func logsChanged(now: Date = Date()) {
        guard watcherAvailable else { return }
        // Anchor coalescing to the first event so continuous writes cannot postpone scans indefinitely.
        changedAt = min(changedAt ?? .distantFuture, now.addingTimeInterval(2))
    }

    public mutating func applicationActive(_ active: Bool) {
        isActive = active
        if let lastLocalStart {
            localAllowed = max(quietUntil, lastLocalStart.addingTimeInterval(active ? 60 : 300))
        }
    }

    public mutating func watcherAvailable(_ available: Bool) {
        watcherAvailable = available
        if !available { changedAt = nil }
    }

    public mutating func takeDueScope(now: Date = Date()) -> SynchronizationScope? {
        guard now >= nextCheck else { return nil }
        let local = now >= max(localAllowed, changedAt ?? .distantFuture)
        let remote = now >= remoteDue
        let scope: SynchronizationScope = remote ? (local ? .all : .remote) : .local
        started(scope, now: now)
        return scope
    }

    public mutating func started(_ scope: SynchronizationScope, now: Date = Date()) {
        if scope == .all || scope == .local {
            lastLocalStart = now
            localAllowed = now.addingTimeInterval(isActive ? 60 : 300)
            changedAt = nil
        }
        if scope == .all || scope == .api || scope == .remote {
            remoteDue = now.addingTimeInterval(300)
            remoteDeadline = now.addingTimeInterval(1800)
        }
    }

    public mutating func acceptedLog(observedAt: Date, now: Date = Date()) {
        guard observedAt <= now, now.timeIntervalSince(observedAt) <= 300 else { return }
        remoteDue = max(remoteDue, min(remoteDeadline, observedAt.addingTimeInterval(300)))
    }

    public mutating func cancelled(now: Date = Date()) {
        changedAt = nil
        quietUntil = now.addingTimeInterval(60)
        localAllowed = max(localAllowed, quietUntil)
        remoteDue = max(remoteDue, quietUntil)
    }
}
