import Foundation

public struct StorageSummary: Sendable {
    public let databaseBytes: Int64
    public let walBytes: Int64
    public let sharedMemoryBytes: Int64
    public var liveBytes: Int64 { databaseBytes + walBytes + sharedMemoryBytes }
}

extension UsageStore {
    /// 仅统计文件长度，不读取历史请求或执行 WAL checkpoint；同步期间大小可继续变化。
    public func storageSummary() throws -> StorageSummary {
        let databaseBytes = try databaseURL.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init) ?? 0
        func sidecarBytes(_ suffix: String) throws -> Int64 {
            do {
                return try URL(fileURLWithPath: databaseURL.path + suffix)
                    .resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init) ?? 0
            } catch CocoaError.fileReadNoSuchFile { return 0 }
        }
        let walBytes = try sidecarBytes("-wal")
        let sharedMemoryBytes = try sidecarBytes("-shm")
        return StorageSummary(databaseBytes: databaseBytes, walBytes: walBytes, sharedMemoryBytes: sharedMemoryBytes)
    }
}
