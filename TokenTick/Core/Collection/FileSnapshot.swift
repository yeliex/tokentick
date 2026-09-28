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
    var sourceIdentity: String?
    var copyFingerprint: String?
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

    init(source: DeviceSourceFile, compressed: Bool) {
        size = source.size
        modifiedAt = source.modifiedAt
        inode = 0
        device = 0
        sourceIdentity = source.identity
        self.compressed = compressed
    }

    func sameFile(as other: Self) -> Bool {
        completed && size == other.size && modifiedAt == other.modifiedAt
            && inode == other.inode && device == other.device && compressed == other.compressed
            && sourceIdentity == other.sourceIdentity
    }

}
