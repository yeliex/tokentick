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
        // 当前结构的数据库可直接加入 WAL 读者，不等待扫描者持有的整文件锁。
        // 旧开发结构在写锁内重建，不能与扫描并发清空。
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
