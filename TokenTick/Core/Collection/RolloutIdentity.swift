import Foundation

public struct RolloutIdentity: Equatable, Sendable {
    public let threadID: UUID
    public let rolloutID: UUID
    public let fileName: String
    public let isCompressed: Bool

    public init?(fileName: String) {
        let compressed = fileName.hasSuffix(".jsonl.zst")
        let canonical = compressed ? String(fileName.dropLast(4)) : fileName
        let pattern = #"^rollout-[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}-[0-9a-fA-F-]{36}(?:_[0-9a-fA-F-]{36})?\.jsonl$"#
        guard canonical.range(of: pattern, options: .regularExpression) != nil else { return nil }
        let ids = canonical.dropFirst(28).dropLast(6).split(separator: "_", omittingEmptySubsequences: false)
        guard let first = ids.first, let last = ids.last,
              let thread = UUID(uuidString: String(first)),
              let rollout = UUID(uuidString: String(last)) else { return nil }
        threadID = thread
        rolloutID = rollout
        self.fileName = canonical
        isCompressed = compressed
    }
}
