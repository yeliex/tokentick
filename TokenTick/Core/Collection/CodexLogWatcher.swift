import CoreServices
import Foundation
import Darwin

/// Treat FSEvents as reconciliation hints, not a complete file inventory; do not read log bodies here.
public final class CodexLogWatcher {
    private let stream: FSEventStreamRef
    private let queue = DispatchQueue(label: "com.yeliex.tokentick.logs", qos: .utility)

    private final class Context: Sendable {
        let root: String
        let changed: @Sendable () -> Void
        init(root: String, changed: @escaping @Sendable () -> Void) { self.root = root; self.changed = changed }
        func relevant(_ path: String) -> Bool {
            // Read-only SQLite connections still update shared-memory locks; watching them would trigger scans recursively.
            if (path.hasPrefix(root + "/state_") || path.hasPrefix(root + "/logs_")), path.hasSuffix(".sqlite-shm") { return false }
            return path == root || path.hasPrefix(root + "/sessions") || path.hasPrefix(root + "/archived_sessions")
                || path == root + "/.codex-global-state.json" || path.hasPrefix(root + "/state_") || path.hasPrefix(root + "/logs_")
                || path == root + "/session_index.jsonl"
        }
    }

    public init(codexHome: URL, onChange: @escaping @Sendable () -> Void) throws {
        // Match the realpath representation used by events; Foundation may shorten /private/var to /var.
        guard let physicalPath = realpath(codexHome.path, nil) else { throw WatchError.unavailable }
        let root = String(cString: physicalPath)
        free(physicalPath)
        let box = Context(root: root, changed: onChange)
        defer { withExtendedLifetime(box) {} }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(box).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                _ = Unmanaged<Context>.fromOpaque(pointer).retain()
                return pointer
            }, release: { pointer in
                if let pointer { Unmanaged<Context>.fromOpaque(pointer).release() }
            }, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
        guard let created = FSEventStreamCreate(nil, { _, info, count, paths, flags, _ in
            guard let info else { return }
            let context = Unmanaged<Context>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let lost = (0..<count).contains { index in
                flags[index] & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped) != 0
            }
            if lost || paths.contains(where: context.relevant) { context.changed() }
        }, &context, [root] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1, flags) else {
            throw WatchError.unavailable
        }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created); FSEventStreamRelease(created)
            throw WatchError.unavailable
        }
        stream = created
    }

    deinit {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    private enum WatchError: LocalizedError {
        case unavailable
        var errorDescription: String? { String(localized: "File notifications are unavailable. Logs will be checked through scheduled scans.", bundle: .module) }
    }
}
