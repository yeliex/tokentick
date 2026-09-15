import Darwin
import Foundation

// The app and CLI share a lock file; the kernel releases the lock when a process exits.
struct FileWriteLock {
    let url: URL
    enum LockError: Error { case busy }

    func withLock<T>(nonBlocking: Bool = false, _ operation: () throws -> T) throws -> T {
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        while true {
            try Task.checkCancellation()
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { break }
            if errno == EINTR { continue }
            guard errno == EWOULDBLOCK else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if nonBlocking { throw LockError.busy }
            // Use bounded waits so cancellation can interrupt a long-running writer before acquiring the lock.
            Thread.sleep(forTimeInterval: 0.05)
        }
        defer { flock(descriptor, LOCK_UN) }
        try Task.checkCancellation()
        return try operation()
    }
}
