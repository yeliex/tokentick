import Foundation
import GRDB

/// Merge windows in memory without storing individual observations; files may arrive out of order.
struct WeeklyCycleCalculator: Sendable {
    struct Window: Codable, Sendable {
        var account: String?
        var reset: Int64
        var first: Double
        var last: Double
        var percent: Double
        var positive: Bool
        var file: String?
        var line: Int?
    }
    var windows: [Window] = []

    mutating func consume(_ snapshot: CurrentLimitSnapshot) {
        guard snapshot.historyExclusion == nil else { return }
        for value in snapshot.windows where value.limitID == "codex" && value.durationMinutes == 10_080 {
            guard let reset = value.resetsAt, snapshot.observedAt < Double(reset),
                  Double(reset) - snapshot.observedAt <= 604_805 else { continue }
            merge(Window(account: snapshot.accountID, reset: reset, first: snapshot.observedAt,
                last: snapshot.observedAt, percent: value.usedPercent, positive: value.usedPercent > 0,
                file: snapshot.fileName, line: snapshot.line))
        }
    }

    mutating func merge(_ window: Window) {
        if let index = windows.firstIndex(where: { $0.account == window.account && abs($0.reset-window.reset) <= 60 }) {
            let first = min(windows[index].first, window.first)
            let positive = windows[index].positive || window.positive
            if window.last > windows[index].last { windows[index] = window }
            windows[index].first = first
            windows[index].positive = positive
        } else {
            windows.append(window)
        }
    }

    func saveCompleted(db: Database, now: Double) throws -> Int {
        var changed = 0
        let ordered = windows.sorted { $0.first < $1.first }
        for (index, window) in ordered.enumerated() where window.positive {
            let next = ordered.dropFirst(index + 1).first { $0.account == window.account && $0.first > window.last }
            let early = next.map { $0.first < Double(window.reset) } == true
            let end = early ? next!.first : Double(window.reset)
            guard end <= now else { continue }
            let scope = window.account.map { "account:" + $0 } ?? "unknown"
            let id = scope + ":codex:" + String(window.reset)
            let values: [(any DatabaseValueConvertible)?] = [window.account,"codex",
                Double(window.reset)-604_800,window.reset,end,early ? "early" : "natural",
                window.last,window.percent,window.file,window.line]
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
        return changed
    }
}
