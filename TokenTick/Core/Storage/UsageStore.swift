import Foundation
import GRDB

public final class UsageStore: Sendable {
    let pool: DatabasePool
    public let databaseURL: URL

    public enum StoreError: Error, LocalizedError, Equatable {
        case newerSchema
        public var errorDescription: String? {
            switch self {
            case .newerSchema: "数据库由更新版本创建，请更新 TokenTick 后再打开。已有数据未修改。"
            }
        }
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
        let migrator = StoreSchema.migrator
        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        // 已完成迁移的数据库可直接加入 WAL 读者，不等待扫描者持有的整文件锁。
        // 需要迁移时仍在锁内重新核对，不能沿用锁外检查结果执行迁移。
        if FileManager.default.fileExists(atPath: databaseURL.path) {
            let existing = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
            let ready = try existing.read { db in
                guard try !migrator.hasBeenSuperseded(db) else { throw StoreError.newerSchema }
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
            if FileManager.default.fileExists(atPath: databaseURL.path) {
                var readConfiguration = Configuration()
                // 已有 WAL 数据库可能没有 sidecar。连接须能创建 SQLite 自身的
                // WAL/SHM，业务 schema 仍只读检查，确认兼容后才执行迁移。
                readConfiguration.busyMode = .timeout(5)
                let previous = try DatabaseQueue(path: databaseURL.path, configuration: readConfiguration)
                let superseded = try previous.read { try migrator.hasBeenSuperseded($0) }
                try previous.close()
                guard !superseded else { throw StoreError.newerSchema }
            }
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
