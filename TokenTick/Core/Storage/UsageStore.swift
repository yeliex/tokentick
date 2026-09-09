import Foundation
import GRDB

public final class UsageStore: Sendable {
    let pool: DatabasePool
    public let databaseURL: URL

    public enum StoreError: Error, Equatable {
        case newerSchema
    }

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
        let lock = FileWriteLock(url: databaseURL.appendingPathExtension("write.lock"))
        pool = try lock.withLock {
            let migrator = StoreSchema.migrator
            if FileManager.default.fileExists(atPath: databaseURL.path) {
                var readConfiguration = Configuration()
                readConfiguration.readonly = true
                let previous = try DatabaseQueue(path: databaseURL.path, configuration: readConfiguration)
                let state = try previous.read { db in
                    (try migrator.hasBeenSuperseded(db), try migrator.hasCompletedMigrations(db))
                }
                guard !state.0 else { throw StoreError.newerSchema }
                if !state.1 {
                    let backupDirectory = directory.appendingPathComponent("Backups", isDirectory: true)
                    try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true,
                                                           attributes: [.posixPermissions: 0o700])
                    let backupURL = backupDirectory.appendingPathComponent("before-migration-\(UUID().uuidString).sqlite")
                    let backup = try DatabaseQueue(path: backupURL.path)
                    try previous.backup(to: backup)
                }
            }
            var configuration = Configuration()
            configuration.busyMode = .timeout(5)
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
