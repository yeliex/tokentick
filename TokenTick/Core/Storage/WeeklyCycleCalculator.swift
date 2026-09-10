import CryptoKit
import Foundation

/// 输入已排除回放、过期及同时间冲突；内存仅保留当前窗口和生成的统计结果。
struct WeeklyCycleCalculator {
    struct Point {
        let id: String
        let account: String?
        let limit: String
        let time: Double
        let reset: Int64
        let percent: Double
        let count: Int
        let conflict: Bool
        let source: String
        var firstObservedAt: Double? = nil
        var peakPercent: Double? = nil
        var lastConflicted = false
    }
    private struct Window {
        var first: Point
        let anchorReset: Int64
        var last: Point
        var peak: Double
        var firstTime: Double
        var count: Int
        var conflicts = 0
        var lastConflicted = false
        init(_ point: Point) {
            first = point; anchorReset = point.reset; last = point
            peak = point.peakPercent ?? point.percent; firstTime = point.firstObservedAt ?? point.time
            count = point.count; lastConflicted = point.lastConflicted
            conflicts = point.lastConflicted ? 1 : 0
        }
        mutating func add(_ point: Point) {
            count += point.count
            if point.time < first.time { first = point }
            firstTime = min(firstTime, point.firstObservedAt ?? point.time)
            peak = max(peak, point.peakPercent ?? point.percent)
            if point.time == last.time && (point.percent != last.percent || point.lastConflicted) { conflicts += 1; lastConflicted = true }
            else if point.time > last.time { last = point; lastConflicted = point.lastConflicted }
        }
        func result(kind: String, next: Point? = nil, confirmation: Point? = nil) throws -> WeeklyLimitReset {
            let scope = first.account.map { "account:" + $0 } ?? "unknown"
            let identity = first.account == nil ? String(anchorReset) : first.id
            let id = SHA256.hash(data: Data("\(scope):\(first.limit):\(identity)".utf8)).map { String(format: "%02x", $0) }.joined()
            var evidence: [String: Any] = ["lastObservationID": last.id,
                "lastSource": last.source, "deadlineToleranceSeconds": 2]
            if first.account != nil { evidence["firstObservationID"] = first.id }
            if let next { evidence["nextObservationID"] = next.id; evidence["nextSource"] = next.source }
            if let confirmation { evidence["confirmationID"] = confirmation.id; evidence["confirmationSource"] = confirmation.source }
            let json = String(decoding: try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys]), as: UTF8.self)
            return WeeklyLimitReset(id: id, accountID: first.account, scopeKey: scope, limitID: first.limit,
                scheduledResetAt: anchorReset, firstObservedAt: firstTime, detectedAt: next?.time,
                confirmedAt: confirmation?.time, resetAt: kind == "natural" ? Double(anchorReset) : nil,
                resetAfter: next == nil || kind == "natural" ? nil : last.time,
                resetBefore: next == nil || kind == "natural" ? nil : next?.time,
                lastObservedAt: last.time, usedPercentBeforeReset: lastConflicted ? nil : last.percent,
                peakUsedPercent: peak, observationCount: count, conflictingObservations: conflicts,
                kind: kind, sourceJSON: json)
        }
    }
    private var current: Window?
    private var pendingDrop: Point?
    private var scope: String?
    var results: [WeeklyLimitReset] = []
    var conflictCount = 0

    mutating func consume(_ point: Point) throws {
        let key = (point.account.map { "account:" + $0 } ?? "unknown") + ":" + point.limit
        if scope != key { try finish(); scope = key }
        if point.conflict { conflictCount += 1; current?.conflicts += 1; return }
        if point.account == nil {
            // 未归属观测只按截止窗口整理，不将不同任务推断成同一个账号的时间线。
            guard point.percent > 0 else { return }
            if let window = current, abs(point.reset - window.anchorReset) > 2 { try finish() }
            if current == nil { current = Window(point) } else { current?.add(point) }
            return
        }
        guard var window = current else {
            if point.percent > 0 { current = Window(point) }
            return
        }
        let sameDeadline = abs(point.reset - window.anchorReset) <= 2
        if let pending = pendingDrop {
            let supportsDrop = point.time > pending.time && point.percent < window.last.percent
                && point.percent >= pending.percent
                && (abs(point.reset - pending.reset) <= 2 || pending.percent == 0)
            if supportsDrop {
                let kind = abs(pending.reset - window.anchorReset) <= 2 ? "drop_unconfirmed" : "manual_suspected"
                results.append(try window.result(kind: kind, next: pending, confirmation: point))
                current = pending.percent > 0 ? Window(pending) : nil
                pendingDrop = nil
                try consume(point)
                return
            }
            window.conflicts += 1; conflictCount += 1
            pendingDrop = nil
        }
        if point.time >= Double(window.anchorReset), point.reset > window.anchorReset + 2 {
            let kind = point.time - Double(window.anchorReset) <= 604_800 ? "natural" : "gap_unconfirmed"
            results.append(try window.result(kind: kind, next: point, confirmation: point))
            current = point.percent > 0 ? Window(point) : nil
        } else if point.percent < window.last.percent {
            current = window
            pendingDrop = point
        } else if !sameDeadline {
            // 截止时间推进但使用量仍增长，只能确认窗口信息变化，不能称为重置。
            results.append(try window.result(kind: "boundary_changed", next: point))
            current = point.percent > 0 ? Window(point) : nil
        } else {
            window.add(point); current = window
        }
    }

    mutating func finish() throws {
        if var window = current {
            if pendingDrop != nil { window.conflicts += 1; conflictCount += 1 }
            results.append(try window.result(kind: window.first.account == nil ? "unattributed" : "observed"))
        }
        current = nil; pendingDrop = nil
    }
}
