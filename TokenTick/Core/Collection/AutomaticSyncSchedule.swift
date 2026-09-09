import Foundation

/// 只安排触发时间；扫描、价格和 API 仍走同一个同步入口。
public struct AutomaticSyncSchedule: Sendable {
    private var localDue: Date
    private var remoteDue: Date
    private var localAllowed: Date
    private var changedAt: Date?

    public init(now: Date = Date()) {
        localDue = now; remoteDue = now; localAllowed = now
    }

    public var nextCheck: Date {
        min(remoteDue, max(localAllowed, min(localDue, changedAt ?? .distantFuture)))
    }

    public mutating func logsChanged(now: Date = Date()) {
        // 连续写入不能无限延后扫描，首个事件确定本批合并时间。
        changedAt = min(changedAt ?? .distantFuture, now.addingTimeInterval(2))
    }

    public mutating func recovered(now: Date = Date()) {
        changedAt = now
    }

    public mutating func takeDueScope(now: Date = Date()) -> SynchronizationScope? {
        guard now >= nextCheck else { return nil }
        let scope: SynchronizationScope = now >= remoteDue ? .all : .local
        started(scope, now: now)
        return scope
    }

    public mutating func started(_ scope: SynchronizationScope, now: Date = Date()) {
        if scope == .all || scope == .local {
            localDue = now.addingTimeInterval(60)
            localAllowed = now.addingTimeInterval(10)
            changedAt = nil
        }
        if scope == .all || scope == .api { remoteDue = now.addingTimeInterval(300) }
    }

    public mutating func cancelled(now: Date = Date()) {
        changedAt = nil
        localAllowed = now.addingTimeInterval(60)
        localDue = max(localDue, localAllowed)
        remoteDue = max(remoteDue, localAllowed)
    }
}
