import Foundation
import Synchronization

/// Native access for the built-in source; collection and storage are shared with SSH.
final class LocalFileSource: DeviceFileSource, DeviceTraceSource {
    let root: URL
    private let catalogReader = Mutex<DeviceCatalogPage.Reader?>(nil)
    init(root: URL) throws { self.root = try DeviceWorker.validatedRoot(root.path) }
    func probe() -> String { root.path }
    func manifest() throws -> DeviceSourceManifest {
        guard case .manifest(let value) = try DeviceWorker.execute(.manifest, root: root) else { throw DeviceSourceFailure.invalidResponse }
        return value
    }
    func manifest(directories: [String]) throws -> DeviceSourceManifest {
        guard case .manifest(let value) = try DeviceWorker.execute(.selectedManifest(directories), root: root) else { throw DeviceSourceFailure.invalidResponse }
        return value
    }
    func read(_ file: DeviceSourceFile, offset: UInt64, count: Int) throws -> Data {
        guard case .bytes(let value) = try DeviceWorker.execute(.read(file, offset: offset, count: count), root: root) else { throw DeviceSourceFailure.invalidResponse }
        return value
    }
    func catalog(after: String?) throws -> DeviceCatalogPage {
        try catalogReader.withLock { reader in
            if reader == nil { reader = try DeviceCatalogPage.Reader(root: root) }
            return try reader!.read(after: after)
        }
    }
    func traceFiles() throws -> [String] { try DeviceTracePage.files(root: root) }
    func tracePage(file: String, cursor: CodexFastEvidence.Cursor?) throws -> DeviceTracePage {
        try DeviceTracePage.read(root: root, file: file, previous: cursor)
    }
}
