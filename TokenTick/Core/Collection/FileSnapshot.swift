import CryptoKit
import Foundation

struct ScanCursor {
    let path: String?
    let line: Int
    let offset: UInt64
    let file: FileSnapshot
    let state: RolloutParserState
}

struct FileSnapshot: Codable {
    let size: UInt64
    let modifiedAt: TimeInterval
    let inode: UInt64
    let device: UInt64
    let compressed: Bool
    var completed = false
    var prefixHash = ""
    var tailHash = ""

    init(url: URL, compressed: Bool) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        modifiedAt = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        device = (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0
        self.compressed = compressed
    }

    func sameFile(as other: Self) -> Bool {
        completed && size == other.size && modifiedAt == other.modifiedAt
            && inode == other.inode && device == other.device && compressed == other.compressed
    }

    func canResume(url: URL, snapshot: Self, offset: UInt64) throws -> Bool {
        guard !compressed, !snapshot.compressed, offset > 0, snapshot.size >= offset,
              inode == snapshot.inode, device == snapshot.device,
              snapshot.size > size || (snapshot.size == size && snapshot.modifiedAt == modifiedAt) else { return false }
        return try Self.hash(url: url, offset: 0, count: Int(min(offset, 4_096))) == prefixHash
            && Self.hash(url: url, offset: offset - min(offset, 4_096), count: Int(min(offset, 4_096))) == tailHash
    }

    static func hash(url: URL, offset: UInt64, count: Int) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: count) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
