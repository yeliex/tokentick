import Darwin
import Foundation

// App 与 CLI 共享同一锁文件；进程退出时由内核释放，不依赖手动清理状态。
struct FileWriteLock {
    let url: URL
    enum LockError: Error { case busy }

    func withLock<T>(nonBlocking: Bool = false, _ operation: () throws -> T) throws -> T {
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX | (nonBlocking ? LOCK_NB : 0)) != 0 {
            if errno == EINTR { continue }
            if nonBlocking && errno == EWOULDBLOCK { throw LockError.busy }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }
}
