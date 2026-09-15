import Foundation
import GRDB
import Synchronization

public final class UsageStore: Sendable {
    let apiMemory = Mutex(APIMemory())
    let weeklyMemory = Mutex(WeeklyCycleCalculator())
    let pool: DatabasePool
    public let databaseURL: URL

    public static var defaultDatabaseURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TokenTick", isDirectory: true)
            .appendingPathComponent("usage.sqlite")
    }

    public init(databaseURL: URL = UsageStore.defaultDatabaseURL) throws {
        self.databaseURL = databaseURL
        let directory = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let migrator = StoreSchema.migrator
        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        // Readers can join a current-schema WAL database without waiting for the scanner's file lock.
        // Rebuild a changed development schema under the write lock to avoid clearing it during a scan.
        if FileManager.default.fileExists(atPath: databaseURL.path) {
            let existing = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
            let ready = try existing.read { db in
                return try migrator.hasCompletedMigrations(db)
            }
            try existing.close()
            if ready {
                pool = try DatabasePool(path: databaseURL.path, configuration: configuration)
                return
            }
        }
        let lock = FileWriteLock(url: databaseURL.appendingPathExtension("write.lock"))
        pool = try lock.withLock {
            let database = try DatabasePool(path: databaseURL.path, configuration: configuration)
            try migrator.migrate(database)
            return database
        }
    }

    public func tableCounts() throws -> [String: Int] {
        try pool.read { db in
            var result: [String: Int] = [:]
            for table in StoreSchema.tables {
                result[table] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
            }
            return result
        }
    }
}
