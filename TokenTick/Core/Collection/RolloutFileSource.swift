import Foundation

/// Source access stays separate from rollout identity, parsing, and destination transactions.
protocol RolloutFileSource: Sendable {
    func enumerate(at root: URL, onError: @escaping (URL, any Error) -> Void,
                   visit: (URL) throws -> Void) throws
    func isRegularFile(_ url: URL) throws -> Bool
    func snapshot(_ url: URL, compressed: Bool) throws -> FileSnapshot
    func open(_ url: URL) throws -> any RolloutFileReading
}

/// One open file per stream; offsets refer to source bytes, including compressed input.
protocol RolloutFileReading: AnyObject {
    func seek(to offset: UInt64) throws
    func read(upToCount count: Int) throws -> Data
}

struct LocalRolloutFileSource: RolloutFileSource {
    func enumerate(at root: URL, onError: @escaping (URL, any Error) -> Void,
                   visit: (URL) throws -> Void) throws {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles],
            errorHandler: { url, error in onError(url, error); return true }
        ) else { return }
        for case let url as URL in enumerator { try visit(url) }
    }

    func isRegularFile(_ url: URL) throws -> Bool {
        try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
    }

    func snapshot(_ url: URL, compressed: Bool) throws -> FileSnapshot {
        try FileSnapshot(url: url, compressed: compressed)
    }

    func open(_ url: URL) throws -> any RolloutFileReading { try LocalRolloutFile(url: url) }
}

private final class LocalRolloutFile: RolloutFileReading {
    private let handle: FileHandle

    init(url: URL) throws { handle = try FileHandle(forReadingFrom: url) }
    deinit { try? handle.close() }
    func seek(to offset: UInt64) throws { try handle.seek(toOffset: offset) }
    func read(upToCount count: Int) throws -> Data { try handle.read(upToCount: count) ?? Data() }
}
