import Darwin
import Foundation
import GRDB
import SQLite3

/// Keep source connections read-only and capture access conditions only when opening fails.
enum CodexSourceDatabase {
    static func open(_ url: URL, busyTimeout: TimeInterval, recoverCheckpointedWAL: Bool = false) throws -> DatabaseQueue {
        var configuration = Configuration()
        configuration.readonly = true
        configuration.busyMode = .timeout(busyTimeout)
        do {
            return try DatabaseQueue(path: url.path, configuration: configuration)
        } catch {
            if recoverCheckpointedWAL, (error as? DatabaseError)?.resultCode == .SQLITE_CANTOPEN,
               let snapshot = try? openCheckpointedSnapshot(url.resolvingSymlinksInPath(), configuration: configuration) {
                return snapshot
            }
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

    private static func openCheckpointedSnapshot(_ url: URL, configuration: Configuration) throws -> DatabaseQueue? {
        func isMissing(_ path: String) -> Bool {
            var status = stat()
            return lstat(path, &status) == -1 && errno == ENOENT
        }

        let wal = url.path + "-wal"
        let shm = url.path + "-shm"
        var before = stat()
        guard stat(url.path, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              isMissing(wal), isMissing(shm) else { return nil }
        let data = try Data(contentsOf: url)
        var after = stat()
        // If a writer creates a WAL or checkpoints during the copy, use the regular SQLite path on the next pass.
        guard isMissing(wal), isMissing(shm), stat(url.path, &after) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, data.count == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              data.count >= 100, data.starts(with: "SQLite format 3\0".utf8),
              data[18] == 2, data[19] == 2 else { return nil }

        let snapshot = try DatabaseQueue(configuration: configuration)
        try snapshot.writeWithoutTransaction { db in
            let count = Int64(data.count)
            guard let buffer = sqlite3_malloc64(UInt64(count)) else {
                throw DatabaseError(resultCode: .SQLITE_NOMEM)
            }
            data.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: data.count)
            // SQLite cannot deserialize WAL mode. Change only the journal format bytes of the private copy.
            let bytes = buffer.assumingMemoryBound(to: UInt8.self)
            bytes[18] = 1
            bytes[19] = 1
            let flags = UInt32(SQLITE_DESERIALIZE_FREEONCLOSE | SQLITE_DESERIALIZE_READONLY)
            let result = sqlite3_deserialize(db.sqliteConnection, "main", bytes, count, count, flags)
            guard result == SQLITE_OK else { throw DatabaseError(resultCode: ResultCode(rawValue: result)) }
            _ = try Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_master")
        }
        return snapshot
    }
}
