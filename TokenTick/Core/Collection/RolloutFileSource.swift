import Foundation

/// Seekable source bytes; compressed input offsets are separate from parsed line offsets.
protocol RolloutFileReading: AnyObject {
    func seek(to offset: UInt64) throws
    func read(upToCount count: Int) async throws -> Data
}

final class LocalRolloutFile: RolloutFileReading {
    private let handle: FileHandle

    init(url: URL) throws { handle = try FileHandle(forReadingFrom: url) }
    deinit { try? handle.close() }
    func seek(to offset: UInt64) throws { try handle.seek(toOffset: offset) }
    func read(upToCount count: Int) throws -> Data {
        // An async caller has no per-file autorelease pool; release Foundation buffers after each read.
        try autoreleasepool { try handle.read(upToCount: count) ?? Data() }
    }
}

/// Read only the discovered file extent; appended bytes belong to the next scan.
final class DeviceRolloutFile: RolloutFileReading {
    private let source: any DeviceFileSource
    private let file: DeviceSourceFile
    private var offset: UInt64 = 0

    init(source: any DeviceFileSource, file: DeviceSourceFile) {
        self.source = source
        self.file = file
    }

    func seek(to offset: UInt64) { self.offset = offset }

    func read(upToCount count: Int) async throws -> Data {
        try Task.checkCancellation()
        guard offset < file.size else { return Data() }
        let count = Int(min(UInt64(count), file.size - offset))
        let data = try await source.read(file, offset: offset, count: count)
        guard data.count == count else { throw DeviceSourceFailure.changed }
        offset += UInt64(count)
        return data
    }
}
