import CryptoKit
import Foundation

/// SQLite 已按截止秒值汇总；内存只保存这些统计点，不加载全部日志观测。
struct WeeklyCycleCalculator {
    // 与用户核对清单一致：容忍秒级偏差，固定锚点阻止连续吸附扩大窗口。
    static let deadlineTolerance: Int64 = 60
    static let idleTolerance: Int64 = 30
    static let duration: Int64 = 604_800

    struct Point {
        let reset: Int64
        let count: Int
        let positiveCount: Int
        let firstTime: Double
        let firstPositiveTime: Double?
        let lastTime: Double
        let lastMinPercent: Double
        let lastMaxPercent: Double
        let peak: Double
        let unknownCount: Int
        let accounts: [String]
        let firstSource: String
        let lastSource: String
        let positiveSource: String?
    }
    struct Recovery {
        let account: String
        let reset: Int64
        let observedAt: Double
        let source: String
    }
    private struct Window {
        let anchor: Int64
        var lastPositiveReset: Int64
        var representative: Point
        var count = 0
        var unknownCount = 0
        var accounts: Set<String> = []
        var first: Point
        var firstPositive: Double
        var last: Point
        var lastMin: Double
        var lastMax: Double
        var peak = 0.0
        var conflicts = 0

        init(_ point: Point) {
            anchor = point.reset; lastPositiveReset = point.reset; representative = point
            first = point; last = point; firstPositive = point.firstPositiveTime!
            lastMin = point.lastMinPercent; lastMax = point.lastMaxPercent
            add(point)
        }
        mutating func add(_ point: Point) {
            count += point.count; unknownCount += point.unknownCount
            accounts.formUnion(point.accounts); peak = max(peak, point.peak)
            if point.firstTime < first.firstTime { first = point }
            if let time = point.firstPositiveTime {
                firstPositive = min(firstPositive, time)
                lastPositiveReset = max(lastPositiveReset, point.reset)
                if point.positiveCount > representative.positiveCount { representative = point }
            }
            if point.lastTime > last.lastTime {
                last = point; lastMin = point.lastMinPercent; lastMax = point.lastMaxPercent
            } else if point.lastTime == last.lastTime {
                lastMin = min(lastMin, point.lastMinPercent); lastMax = max(lastMax, point.lastMaxPercent)
            }
            if point.lastMinPercent != point.lastMaxPercent { conflicts += 1 }
        }
    }

    let scope: UsageAccountScope
    private var points: [Point] = []
    init(scope: UsageAccountScope) { self.scope = scope }
    mutating func consume(_ point: Point) { points.append(point) }

    func windows(recoveries: [Recovery]) throws -> [WeeklyLimitWindow] {
        // 只有正用量能固定周期。单独的滚动零值不能建立窗口或改变代表截止。
        var groups: [Window] = []
        for point in points where point.positiveCount > 0 {
            if let last = groups.last, point.reset - last.anchor <= Self.deadlineTolerance {
                groups[groups.count - 1].add(point)
            } else { groups.append(Window(point)) }
        }
        var index = 0
        for point in points where point.positiveCount == 0 {
            while index < groups.count && point.reset > groups[index].lastPositiveReset + Self.idleTolerance { index += 1 }
            guard index < groups.count, point.reset >= groups[index].anchor - Self.idleTolerance else { continue }
            groups[index].add(point)
        }
        return try groups.map { group in
            let deadline = group.representative.reset
            let key = scope.weeklyScopeKey
            let id = SHA256.hash(data: Data("\(key):codex:\(group.anchor)".utf8)).map { String(format: "%02x", $0) }.joined()
            let accounts = group.accounts.sorted()
            // 全局合并不等于给未知日志补账号；账号查询的输入已由 SQLite 严格筛选。
            let account = group.unknownCount == 0 && accounts.count == 1 ? accounts.first : nil
            let candidates = recoveries.filter { abs($0.reset - deadline) <= Self.deadlineTolerance && group.accounts.contains($0.account) }
            let recovery = Set(candidates.map(\.account)).count == 1 ? candidates.min(by: { $0.observedAt < $1.observedAt }) : nil
            var evidence: [String: Any] = ["firstSource": group.first.firstSource, "lastSource": group.last.lastSource,
                "stableDeadlineSource": group.representative.positiveSource ?? group.representative.firstSource,
                "deadlineToleranceSeconds": Self.deadlineTolerance, "idleToleranceSeconds": Self.idleTolerance,
                "deadlineMin": group.anchor, "deadlineMax": group.lastPositiveReset]
            if let recovery { evidence["recoverySource"] = recovery.source; evidence["recoveryAccountID"] = recovery.account }
            let json = String(decoding: try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys]), as: UTF8.self)
            return WeeklyLimitWindow(id: id, accountID: account, scopeKey: key, limitID: "codex",
                startedAtInferred: deadline - Self.duration, scheduledResetAt: deadline,
                firstObservedAt: group.first.firstTime, firstPositiveAt: group.firstPositive,
                lastObservedAt: group.last.lastTime, lastUsedPercent: group.lastMin == group.lastMax ? group.lastMin : nil,
                peakUsedPercent: group.peak, observationCount: group.count,
                conflictingObservations: max(group.conflicts, group.lastMin != group.lastMax ? 1 : 0),
                unknownAccountObservations: group.unknownCount, observedAccountIDs: accounts,
                recoveryObservedAt: recovery?.observedAt, sourceJSON: json)
        }
    }
}
