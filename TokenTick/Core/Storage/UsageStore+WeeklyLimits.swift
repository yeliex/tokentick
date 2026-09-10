import CryptoKit
import Foundation
import GRDB

extension UsageStore {
    static func saveWeeklyObservations(_ snapshot: CurrentLimitSnapshot, db: Database) throws -> Int {
        var inserted = 0
        for window in snapshot.windows where window.limitID == "codex" && window.durationMinutes == 10_080 {
            guard let reset = window.resetsAt, reset > 0 else { continue }
            let evidence = WeeklyEvidence(source: snapshot.source, fileName: snapshot.fileName, line: snapshot.line, window: window)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let json = String(decoding: try encoder.encode(evidence), as: UTF8.self)
            let signature = try JSONSerialization.data(withJSONObject: [snapshot.scopeKey, window.limitID,
                snapshot.observedAt, reset, window.usedPercent], options: [.sortedKeys])
            let key = SHA256.hash(data: signature).map { String(format: "%02x", $0) }.joined()
            try db.execute(sql: """
                INSERT INTO weekly_limit_observations(id, scope_key, account_id, limit_id, observed_at, resets_at, used_percent, source_json, turn_id, exclusion_reason, collected_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET turn_id=excluded.turn_id, exclusion_reason=excluded.exclusion_reason,
                    collected_at=excluded.collected_at, source_json=excluded.source_json
                WHERE weekly_limit_observations.turn_id IS NOT excluded.turn_id
                    OR weekly_limit_observations.exclusion_reason IS NOT excluded.exclusion_reason
                """, arguments: [key, snapshot.scopeKey, snapshot.accountID, window.limitID,
                                  snapshot.observedAt, reset, window.usedPercent, json, snapshot.turnID, snapshot.historyExclusion, Date().timeIntervalSince1970])
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
