import Foundation
import GRDB

/// Keep compact per-window evidence so late files and restarts use the same chronological decisions.
struct WeeklyCycleCalculator: Sendable {
    struct Window: Codable, Sendable, Equatable {
        var account: String?
        var reset: Int64
        var first: Double
        var last: Double
        var percent: Double
        var positive: Bool
        var file: String?
        var line: Int?
        var observedFirst: Double? = nil
        var initialPercent: Double? = nil
        var firstLine: Int? = nil
        var lastMessage: Double? = nil
        var peak: Reading? = nil
    }
    struct Reading: Codable, Sendable, Equatable {
        let time: Double
        let message: Double
        let percent: Double
        let line: Int?
    }
    var windows: [Window] = []

    mutating func consume(_ snapshot: CurrentLimitSnapshot) {
        guard snapshot.historyExclusion == nil else { return }
        for value in snapshot.windows where value.limitID == "codex" && value.durationMinutes == 10_080 {
            guard let reset = value.resetsAt, snapshot.observedAt < Double(reset),
                  snapshot.observedAt.isFinite else { continue }
            let first = snapshot.turnStartedAt ?? snapshot.observedAt
            let reading = Window(account: snapshot.accountID, reset: reset, first: first,
                last: snapshot.observedAt, percent: value.usedPercent, positive: value.usedPercent > 0,
                file: snapshot.fileName, line: snapshot.line, observedFirst: snapshot.observedAt,
                initialPercent: value.usedPercent, firstLine: snapshot.line, lastMessage: first,
                peak: Reading(time: snapshot.observedAt, message: first, percent: value.usedPercent, line: snapshot.line))
            if let index = windows.indices.last, windows[index].account == reading.account,
               windows[index].file == reading.file, abs(windows[index].reset-reading.reset) <= 60 {
                combine(reading, at: index)
            } else { windows.append(reading) }
        }
    }

    private mutating func combine(_ window: Window, at index: Int) {
        let previous = windows[index]
        let earliest = (window.observedFirst ?? window.first) < (previous.observedFirst ?? previous.first) ? window : previous
        if window.last > previous.last { windows[index] = window }
        windows[index].first = min(previous.first, window.first)
        windows[index].positive = previous.positive || window.positive
        windows[index].observedFirst = earliest.observedFirst
        windows[index].initialPercent = earliest.initialPercent
        windows[index].firstLine = earliest.firstLine
        if let peak = previous.peak, peak.percent >= (window.peak?.percent ?? -1) { windows[index].peak = peak }
        else { windows[index].peak = window.peak }
    }

    mutating func merge(_ window: Window) {
        if let index = windows.firstIndex(where: {
            $0.account == window.account && $0.file == window.file && $0.observedFirst == window.observedFirst
                && abs($0.reset-window.reset) <= 60
        }) { combine(window, at: index) }
        else { windows.append(window) }
    }

    func saveCompleted(db: Database, now: Double) throws -> Int {
        struct Cycle {
            var window: Window
            var start: Double
            var end: Double
            var early = false
        }
        var cycles: [Cycle] = []
        var readings: [Window] = []
        for window in windows {
            var first = window
            first.last = window.observedFirst ?? window.first
            first.percent = window.initialPercent ?? window.percent
            first.line = window.firstLine
            first.positive = first.percent > 0
            readings.append(first)
            if let peak = window.peak, peak.time > first.last, peak.time < window.last {
                var middle = window
                middle.last = peak.time; middle.first = peak.message
                middle.percent = peak.percent; middle.line = peak.line
                readings.append(middle)
            }
            if window.last > first.last {
                var last = window
                last.first = window.lastMessage ?? window.first
                readings.append(last)
            }
        }
        readings.sort { $0.last == $1.last ? $0.reset < $1.reset : $0.last < $1.last }
        // Establish cycle identity before relating cycles, independent of file order.
        var groups: [[Window]] = []
        for reading in readings {
            if let index = groups.firstIndex(where: {
                $0[0].account == reading.account && abs($0[0].reset - reading.reset) <= 60
            }) {
                groups[index].append(reading)
            } else {
                groups.append([reading])
            }
        }
        var pending: [String: Window] = [:]
        for reading in readings {
            let key = reading.account.map { "account:" + $0 } ?? "unknown"
            if let index = cycles.lastIndex(where: { $0.window.account == reading.account }) {
                let previous = cycles[index]
                guard reading.last > previous.window.last else { continue }
                if abs(reading.reset - previous.window.reset) <= 60 {
                    cycles[index].window = reading
                    cycles[index].window.percent = max(previous.window.percent, reading.percent)
                    cycles[index].window.positive = previous.window.positive || reading.positive
                    cycles[index].end = Double(reading.reset)
                    pending.removeValue(forKey: key)
                    continue
                }
                if reading.last < previous.end {
                    if let candidate = pending[key], abs(candidate.reset - reading.reset) <= 60,
                       reading.last > candidate.last {
                        guard let group = groups.first(where: { $0[0].account == candidate.account && abs($0[0].reset - candidate.reset) <= 60 }),
                              group.contains(where: { $0.percent > 0 }), let candidateLast = group.last?.last else { continue }
                        let continued = readings.contains {
                            $0.account == previous.window.account && abs($0.reset - previous.window.reset) <= 60
                                && $0.last > candidateLast && $0.last < Double(previous.window.reset)
                                && $0.percent > previous.window.percent
                        }
                        if continued {
                            pending.removeValue(forKey: key)
                            continue
                        }
                        cycles[index].end = candidate.last
                        cycles[index].early = true
                        cycles.append(Cycle(window: reading, start: candidate.last, end: Double(reading.reset)))
                        pending.removeValue(forKey: key)
                    } else if reading.reset > previous.window.reset + 60, previous.window.percent > 1,
                              reading.percent <= 5 {
                        pending[key] = reading
                    }
                    continue
                }
                pending.removeValue(forKey: key)
            }
            cycles.append(Cycle(window: reading, start: reading.last, end: Double(reading.reset)))
        }
        var changed = 0
        var kept: Set<String> = []
        for cycle in cycles where cycle.window.positive && cycle.end <= now {
            let window = cycle.window
            let existing = try Row.fetchOne(db, sql: """
                SELECT * FROM weekly_limit_cycles WHERE account_id IS ? AND limit_id='codex'
                    AND ABS(scheduled_reset_at-?)<=60 ORDER BY ABS(scheduled_reset_at-?) LIMIT 1
                """, arguments: [window.account,window.reset,window.reset])
            let scope = window.account.map { "account:" + $0 } ?? "unknown"
            let id = existing?["id"] as String? ?? scope + ":codex:" + String(window.reset)
            kept.insert(id)
            let values: [(any DatabaseValueConvertible)?] = [window.account,"codex",cycle.start,window.reset,cycle.end,
                cycle.early ? "early" : "natural",window.last,window.percent,window.file,window.line]
            let columns = ["account_id","limit_id","started_at","scheduled_reset_at","ended_at",
                "reset_kind","last_observed_at","last_used_percent","source_file","source_line"]
            let updates = columns.map { "\($0)=excluded.\($0)" }.joined(separator: ",")
            let differences = columns.map { "weekly_limit_cycles.\($0) IS NOT excluded.\($0)" }.joined(separator: " OR ")
            try db.execute(sql: """
                INSERT INTO weekly_limit_cycles(id,\(columns.joined(separator: ","))) VALUES (?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET \(updates) WHERE \(differences)
                """, arguments: StatementArguments([id] + values))
            changed += db.changesCount
        }
        // Later files can disprove a provisional cycle. Remove only windows represented in this reconstruction.
        for row in try Row.fetchAll(db, sql: "SELECT id,account_id,scheduled_reset_at FROM weekly_limit_cycles") {
            let id: String = row["id"], account: String? = row["account_id"], reset: Int64 = row["scheduled_reset_at"]
            if !kept.contains(id), windows.contains(where: { $0.account == account && abs($0.reset-reset) <= 60 }) {
                try db.execute(sql: "DELETE FROM weekly_limit_cycles WHERE id=?", arguments: [id])
                changed += db.changesCount
            }
        }
        return changed
    }
}
