import Foundation

public struct MigrationBackup: Sendable, Identifiable {
    public var id: String { url.lastPathComponent }
    public let url: URL
    public let bytes: Int64
    public let modifiedAt: Date?
}

public struct StorageSummary: Sendable {
    public let databaseBytes: Int64
    public let walBytes: Int64
    public let sharedMemoryBytes: Int64
    public let backupDirectory: URL
    public let backupBytes: Int64
    public let backupCount: Int
    public let recentBackups: [MigrationBackup]
    public var liveBytes: Int64 { databaseBytes + walBytes + sharedMemoryBytes }
}

extension UsageStore {
    /// 仅统计文件长度，不读取历史请求或执行 WAL checkpoint；同步期间大小可继续变化。
    public func storageSummary() throws -> StorageSummary {
        let files = FileManager.default
        let databaseBytes = try databaseURL.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init) ?? 0
        func sidecarBytes(_ suffix: String) throws -> Int64 {
            do {
                return try URL(fileURLWithPath: databaseURL.path + suffix)
                    .resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init) ?? 0
            } catch CocoaError.fileReadNoSuchFile { return 0 }
        }
        let walBytes = try sidecarBytes("-wal")
        let sharedMemoryBytes = try sidecarBytes("-shm")
        let backupDirectory = databaseURL.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true)
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]
        let candidates: [URL]
        do { candidates = try files.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: Array(keys)) }
        catch CocoaError.fileReadNoSuchFile { candidates = [] }
        var backups: [MigrationBackup] = []
        var count = 0
        var bytes: Int64 = 0
        for url in candidates where url.lastPathComponent.hasPrefix("before-migration-") && url.pathExtension == "sqlite" {
            let values: URLResourceValues
            do { values = try url.resourceValues(forKeys: keys) }
            catch CocoaError.fileReadNoSuchFile { continue }
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let backup = MigrationBackup(url: url, bytes: Int64(values.fileSize ?? 0), modifiedAt: values.contentModificationDate)
            count += 1; bytes += backup.bytes
            backups.append(backup)
            backups.sort {
                if $0.modifiedAt != $1.modifiedAt { return ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
                return $0.id < $1.id
            }
            if backups.count > 20 { backups.removeLast() }
        }
        return StorageSummary(databaseBytes: databaseBytes, walBytes: walBytes, sharedMemoryBytes: sharedMemoryBytes,
            backupDirectory: backupDirectory, backupBytes: bytes, backupCount: count, recentBackups: backups)
    }
}
