import Foundation
import GRDB

public struct StatisticsRebuildReport: Codable, Sendable {
    public let timezone: String
    public let revision: Int64
    public let rows: Int
    public let rebuilt: Bool
}

extension UsageStore {
    public func statisticsTimezone() throws -> String {
        try pool.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM app_metadata WHERE key = 'statistics_timezone'") ?? "UTC"
        }
    }

    public func setStatisticsTimezone(_ identifier: String) throws {
        guard let timezone = TimeZone(identifier: identifier) else { throw UsageQueryError.invalidTimezone }
        try FileWriteLock(url: databaseURL.appendingPathExtension("write.lock")).withLock {
            try pool.write { db in
                try db.execute(sql: "UPDATE app_metadata SET value = ? WHERE key = 'statistics_timezone'", arguments: [timezone.identifier])
                let dirty = try Self.statisticsAreCurrent(db, timezone: timezone.identifier) ? "false" : "true"
                try db.execute(sql: "UPDATE app_metadata SET value = ? WHERE key = 'statistics_dirty'", arguments: [dirty])
            }
        }
    }

    public func rebuildStatistics(timezone identifier: String? = nil) throws -> StatisticsRebuildReport {
        let identifier = try identifier ?? statisticsTimezone()
        guard let timezone = TimeZone(identifier: identifier) else { throw UsageQueryError.invalidTimezone }
        return try rebuildStatistics(timezone: timezone, onlyIfNeeded: false)
    }

    func rebuildStatistics(timezone: TimeZone, onlyIfNeeded: Bool) throws -> StatisticsRebuildReport {
        try FileWriteLock(url: databaseURL.appendingPathExtension("write.lock")).withLock(nonBlocking: onlyIfNeeded) {
            try pool.write { db in
                let revision = try Self.statisticsRevision(db)
                if try onlyIfNeeded && Self.statisticsAreCurrent(db, timezone: timezone.identifier) {
                    return StatisticsRebuildReport(timezone: timezone.identifier, revision: revision,
                        rows: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM statistics WHERE timezone = ?", arguments: [timezone.identifier]) ?? 0,
                        rebuilt: false)
                }
                StatisticsSQL.prepare(db, timezone: timezone)
                try db.execute(sql: "DELETE FROM statistics WHERE timezone = ?", arguments: [timezone.identifier])
                try db.execute(sql: "INSERT INTO statistics (\(StatisticsSQL.columns)) \(StatisticsSQL.aggregate)",
                               arguments: ["timezone": timezone.identifier])
                let rows = db.changesCount
                try db.execute(sql: "INSERT INTO app_metadata(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                               arguments: ["statistics_cache_revision:\(timezone.identifier)", String(revision)])
                try db.execute(sql: """
                    UPDATE app_metadata SET value = 'false' WHERE key = 'statistics_dirty'
                    AND (SELECT value FROM app_metadata WHERE key = 'statistics_timezone') = ?
                    """, arguments: [timezone.identifier])
                return StatisticsRebuildReport(timezone: timezone.identifier, revision: revision, rows: rows, rebuilt: true)
            }
        }
    }

    static func statisticsRevision(_ db: Database) throws -> Int64 {
        try Int64.fetchOne(db, sql: "SELECT CAST(value AS INTEGER) FROM app_metadata WHERE key = 'statistics_revision'") ?? 0
    }

    static func statisticsAreCurrent(_ db: Database, timezone: String) throws -> Bool {
        let cached = try Int64.fetchOne(db, sql: "SELECT CAST(value AS INTEGER) FROM app_metadata WHERE key = ?",
                                       arguments: ["statistics_cache_revision:\(timezone)"])
        return try cached == statisticsRevision(db)
    }
}
