import Foundation
import GRDB

public struct StatisticsRebuildReport: Codable, Sendable {
    public let timezone: String
    public let revision: Int64
    public let rows: Int
    public let rebuilt: Bool
}

private struct StatisticsRebuildCheckpoint: Codable {
    // 聚合口径或断点结构改变时递增，使此前的中间结果重新计算。
    static let currentVersion = 1
    let version: Int
    let revision: Int64
    var lastID: Int64 = 0
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
            while true {
                try Task.checkCancellation()
                if let report = try pool.write({ db -> StatisticsRebuildReport? in
                    let revision = try Self.statisticsRevision(db)
                    if try onlyIfNeeded && Self.statisticsAreCurrent(db, timezone: timezone.identifier) {
                        return StatisticsRebuildReport(timezone: timezone.identifier, revision: revision,
                            rows: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM statistics WHERE timezone = ?", arguments: [timezone.identifier]) ?? 0,
                            rebuilt: false)
                    }
                    StatisticsSQL.prepare(db, timezone: timezone)
                    let key = "statistics_rebuild_checkpoint:\(timezone.identifier)"
                    let json = try String.fetchOne(db, sql: "SELECT value FROM app_metadata WHERE key = ?", arguments: [key])
                    var checkpoint: StatisticsRebuildCheckpoint
                    if let json, let saved = try? JSONDecoder().decode(StatisticsRebuildCheckpoint.self, from: Data(json.utf8)),
                       saved.version == StatisticsRebuildCheckpoint.currentVersion, saved.revision == revision, saved.lastID >= 0 {
                        checkpoint = saved
                    } else {
                        try db.execute(sql: "DELETE FROM statistics_rebuild WHERE timezone = ?", arguments: [timezone.identifier])
                        checkpoint = StatisticsRebuildCheckpoint(version: StatisticsRebuildCheckpoint.currentVersion, revision: revision)
                    }
                    if let endID = try Int64.fetchOne(db, sql: "SELECT MAX(id) FROM (SELECT id FROM usage WHERE id > ? ORDER BY id LIMIT 8192)",
                                                     arguments: [checkpoint.lastID]) {
                        try db.execute(sql: "INSERT INTO statistics_rebuild (\(StatisticsSQL.columns)) \(StatisticsSQL.aggregate(predicate: "u.id > :lastID AND u.id <= :endID"))",
                                       arguments: ["timezone": timezone.identifier, "lastID": checkpoint.lastID, "endID": endID])
                        checkpoint.lastID = endID
                        let value = String(decoding: try JSONEncoder().encode(checkpoint), as: UTF8.self)
                        // 断点与中间聚合必须同一事务提交，重试才能既不遗漏也不重复。
                        try db.execute(sql: "INSERT INTO app_metadata(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                                       arguments: [key, value])
                        return nil
                    }
                    try db.execute(sql: "DELETE FROM statistics WHERE timezone = ?", arguments: [timezone.identifier])
                    try db.execute(sql: "INSERT INTO statistics (\(StatisticsSQL.columns)) \(StatisticsSQL.mergeStaged)",
                                   arguments: ["timezone": timezone.identifier])
                    let rows = db.changesCount
                    try db.execute(sql: "INSERT INTO app_metadata(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                                   arguments: ["statistics_cache_revision:\(timezone.identifier)", String(revision)])
                    try db.execute(sql: """
                        UPDATE app_metadata SET value = 'false' WHERE key = 'statistics_dirty'
                        AND (SELECT value FROM app_metadata WHERE key = 'statistics_timezone') = ?
                        """, arguments: [timezone.identifier])
                    try db.execute(sql: "DELETE FROM statistics_rebuild WHERE timezone = ?", arguments: [timezone.identifier])
                    try db.execute(sql: "DELETE FROM app_metadata WHERE key = ?", arguments: [key])
                    return StatisticsRebuildReport(timezone: timezone.identifier, revision: revision, rows: rows, rebuilt: true)
                }) { return report }
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
