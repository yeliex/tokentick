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
            try Task.checkCancellation()
            return try pool.write { db in
                let revision = try Self.statisticsRevision(db)
                if try onlyIfNeeded && Self.statisticsAreCurrent(db, timezone: timezone.identifier) {
                    return StatisticsRebuildReport(timezone: timezone.identifier, revision: revision,
                        rows: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM statistics WHERE timezone=?", arguments: [timezone.identifier]) ?? 0,
                        rebuilt: false)
                }
                StatisticsSQL.prepare(db, timezone: timezone)
                let cached = try Int64.fetchOne(db, sql: "SELECT CAST(value AS INTEGER) FROM app_metadata WHERE key=?",
                    arguments: ["statistics_cache_revision:\(timezone.identifier)"])
                var predicate = "1"
                var arguments: StatementArguments = ["timezone": timezone.identifier]
                if onlyIfNeeded, let cached {
                    let changed = try String.fetchAll(db, sql: "SELECT substr(key,16) FROM app_metadata WHERE key LIKE 'statistics_day:%' AND CAST(value AS INTEGER)>?",
                        arguments: [cached])
                    // UTC 变更日覆盖相邻本地日期，兼容时区偏移和夏令时，不扩大显示查询范围。
                    var days: Set<String> = changed.isEmpty ? [] : ["unknown"]
                    for day in changed {
                        days.insert(day)
                        if day != "unknown" {
                            for offset in [-1,1] {
                                if let adjacent = try String.fetchOne(db, sql: "SELECT date(?,?)", arguments: [day,"\(offset) days"]) { days.insert(adjacent) }
                            }
                        }
                    }
                    let names = days.sorted().enumerated().map { index, day -> String in
                        let key = "day\(index)"; arguments += [key: day]; return ":" + key
                    }
                    predicate = names.isEmpty ? "0" : "(\(StatisticsSQL.dayExpression)) IN (\(names.joined(separator: ",")))"
                    let deletion = names.isEmpty ? "0" : "date IN (\(names.joined(separator: ",")))"
                    try db.execute(sql: "DELETE FROM statistics WHERE timezone=:timezone AND \(deletion)", arguments: arguments)
                } else {
                    try db.execute(sql: "DELETE FROM statistics WHERE timezone=:timezone", arguments: arguments)
                }
                try db.execute(sql: "INSERT INTO statistics (\(StatisticsSQL.columns)) \(StatisticsSQL.aggregate(predicate: predicate))",
                    arguments: arguments)
                let rows = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM statistics WHERE timezone=?", arguments: [timezone.identifier]) ?? 0
                try Task.checkCancellation()
                try db.execute(sql: "INSERT INTO app_metadata(key,value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                    arguments: ["statistics_cache_revision:\(timezone.identifier)", String(revision)])
                try db.execute(sql: "UPDATE app_metadata SET value='false' WHERE key='statistics_dirty' AND (SELECT value FROM app_metadata WHERE key='statistics_timezone')=?", arguments: [timezone.identifier])
                try db.execute(sql: """
                    DELETE FROM app_metadata WHERE key LIKE 'statistics_day:%' AND CAST(value AS INTEGER) <=
                        (SELECT MIN(CAST(value AS INTEGER)) FROM app_metadata WHERE key LIKE 'statistics_cache_revision:%')
                    """)
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
