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

    func canResume(url: URL, snapshot: Self, offset: UInt64, source: any RolloutFileSource) throws -> Bool {
        guard !compressed, !snapshot.compressed, offset > 0, snapshot.size >= offset,
              inode == snapshot.inode, device == snapshot.device,
              snapshot.size > size || (snapshot.size == size && snapshot.modifiedAt == modifiedAt) else { return false }
        return try Self.hash(url: url, offset: 0, count: Int(min(offset, 4_096)), source: source) == prefixHash
            && Self.hash(url: url, offset: offset - min(offset, 4_096), count: Int(min(offset, 4_096)), source: source) == tailHash
    }

    func checkpoint(url: URL, offset: UInt64, completed: Bool, source: any RolloutFileSource) throws -> Self {
        var file = self
        file.completed = completed
        if !compressed {
            file.prefixHash = try Self.hash(url: url, offset: 0, count: Int(min(offset, 4_096)), source: source)
            file.tailHash = try Self.hash(url: url, offset: offset - min(offset, 4_096), count: Int(min(offset, 4_096)), source: source)
        }
        return file
    }

    static func hash(url: URL, offset: UInt64, count: Int, source: any RolloutFileSource) throws -> String {
        let handle = try source.open(url)
        try handle.seek(to: offset)
        let data = try handle.read(upToCount: count)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
