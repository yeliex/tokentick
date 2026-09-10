import CryptoKit
import Foundation
import GRDB

extension UsageStore {
    static func saveWeeklyObservations(_ snapshot: CurrentLimitSnapshot, db: Database) throws -> Int {
        var inserted = 0
        for window in snapshot.windows where window.durationMinutes == 10_080 {
            guard let reset = window.resetsAt, reset > 0 else { continue }
            let evidence = WeeklyEvidence(source: snapshot.source, fileName: snapshot.fileName, line: snapshot.line, window: window)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let json = String(decoding: try encoder.encode(evidence), as: UTF8.self)
            let signature = try JSONSerialization.data(withJSONObject: [snapshot.scopeKey, window.limitID,
                snapshot.observedAt, reset, window.usedPercent], options: [.sortedKeys])
            let key = SHA256.hash(data: signature).map { String(format: "%02x", $0) }.joined()
            try db.execute(sql: """
                INSERT INTO weekly_limit_observations(id, scope_key, account_id, limit_id, observed_at, resets_at, used_percent, source_json)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO NOTHING
                """, arguments: [key, snapshot.scopeKey, snapshot.accountID, window.limitID,
                                  snapshot.observedAt, reset, window.usedPercent, json])
            inserted += db.changesCount
        }
        return inserted
    }

    private struct WeeklyEvidence: Codable {
        let source: String
        let fileName: String?
        let line: Int?
        let window: CurrentLimitWindow
    }
}
