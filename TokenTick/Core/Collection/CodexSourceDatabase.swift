import Foundation
import GRDB

/// Keep source connections read-only and capture access conditions only when opening fails.
enum CodexSourceDatabase {
    static func open(_ url: URL, busyTimeout: TimeInterval) throws -> DatabaseQueue {
        var configuration = Configuration()
        configuration.readonly = true
        configuration.busyMode = .timeout(busyTimeout)
        do {
            return try DatabaseQueue(path: url.path, configuration: configuration)
        } catch {
            let manager = FileManager.default
            let paths = [url.path, url.path + "-wal", url.path + "-shm", url.deletingLastPathComponent().path]
            let access = paths.map { path -> String in
                var directory: ObjCBool = false
                let exists = manager.fileExists(atPath: path, isDirectory: &directory)
                return "\(path): exists=\(exists), directory=\(directory.boolValue), readable=\(manager.isReadableFile(atPath: path)), writable=\(manager.isWritableFile(atPath: path))"
            }.joined(separator: "; ")
            let code = (error as? DatabaseError).map { Int($0.extendedResultCode.rawValue) } ?? (error as NSError).code
            throw NSError(domain: "TokenTickCore.CodexSourceDatabase", code: code, userInfo: [
                NSLocalizedDescriptionKey: "SQLite open failed (code \(code)): \(error.localizedDescription). \(access)",
                NSFilePathErrorKey: url.path,
                NSUnderlyingErrorKey: error
            ])
        }
    }
}
