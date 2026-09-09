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
        while true {
            try Task.checkCancellation()
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { break }
            if errno == EINTR { continue }
            guard errno == EWOULDBLOCK else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if nonBlocking { throw LockError.busy }
            // 另一个进程可能扫描数分钟；有限等待让取消能在获得写锁前生效。
            Thread.sleep(forTimeInterval: 0.05)
        }
        defer { flock(descriptor, LOCK_UN) }
        try Task.checkCancellation()
        return try operation()
    }
}
