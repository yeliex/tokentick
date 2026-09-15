import Foundation
import GRDB

/// 仅在内存合并窗口，不保存逐次观察；不同文件的事件可以乱序到达。
struct WeeklyCycleCalculator: Sendable {
    struct Window: Sendable {
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
    var restoredFiles: Set<String> = []

    mutating func consume(_ snapshot: CurrentLimitSnapshot) {
        guard snapshot.historyExclusion == nil else { return }
        for value in snapshot.windows where value.limitID == "codex" && value.durationMinutes == 10_080 {
            guard let reset = value.resetsAt, snapshot.observedAt < Double(reset),
                  Double(reset) - snapshot.observedAt <= 604_805 else { continue }
            if let index = windows.firstIndex(where: { $0.account == snapshot.accountID && abs($0.reset-reset) <= 60 }) {
                windows[index].first = min(windows[index].first, snapshot.observedAt)
                windows[index].positive = windows[index].positive || value.usedPercent > 0
                if snapshot.observedAt > windows[index].last {
                    windows[index].last = snapshot.observedAt
                    windows[index].percent = value.usedPercent
                    windows[index].file = snapshot.fileName
                    windows[index].line = snapshot.line
                }
            } else {
                windows.append(Window(account: snapshot.accountID, reset: reset, first: snapshot.observedAt,
                    last: snapshot.observedAt, percent: value.usedPercent, positive: value.usedPercent > 0,
                    file: snapshot.fileName, line: snapshot.line))
            }
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
