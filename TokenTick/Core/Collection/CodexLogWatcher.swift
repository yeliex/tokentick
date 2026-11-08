import CoreServices
import Foundation
import Darwin

/// nil requests full discovery; an empty set requests metadata collection only.
public struct CodexLogChanges: Sendable, Equatable {
    public private(set) var directories: Set<String>?

    public init(directories: Set<String>? = []) { self.directories = directories }

    public mutating func merge(_ other: Self) {
        guard let incoming = other.directories, directories != nil else { directories = nil; return }
        directories?.formUnion(incoming)
    }

    static func events(root: String, paths: [String], flags: [FSEventStreamEventFlags]) -> Self? {
        var changes: Self?
        for (path, flag) in zip(paths, flags) {
            if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged
                | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped) != 0 {
                return Self(directories: nil)
            }
            // Preserve /private in FSEvents paths to match the realpath root.
            let path = path.hasSuffix("/") ? String(path.dropLast()) : path
            guard path.hasPrefix(root + "/") else {
                if path == root { return Self(directories: nil) }
                continue
            }
            let relative = String(path.dropFirst(root.count + 1))
            if relative == "sessions" || relative.hasPrefix("sessions/")
                || relative == "archived_sessions" || relative.hasPrefix("archived_sessions/") {
                let directory = flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile) != 0
                    ? (relative as NSString).deletingLastPathComponent : relative
                if changes == nil { changes = Self() }
                changes?.merge(Self(directories: [directory]))
            } else if relative == ".codex-global-state.json" || relative == "session_index.jsonl"
                || ((relative.hasPrefix("state_") || relative.hasPrefix("logs_")) && !relative.hasSuffix(".sqlite-shm")) {
                if changes == nil { changes = Self() }
            }
        }
        return changes
    }
}

/// Treat FSEvents as reconciliation hints, not a complete file inventory; do not read log bodies here.
public final class CodexLogWatcher {
    private let stream: FSEventStreamRef
    private let queue = DispatchQueue(label: "com.yeliex.tokentick.logs", qos: .utility)

    private final class Context: Sendable {
        let root: String
        let changed: @Sendable (CodexLogChanges) -> Void
        init(root: String, changed: @escaping @Sendable (CodexLogChanges) -> Void) { self.root = root; self.changed = changed }
    }

    public init(codexHome: URL, onChange: @escaping @Sendable (CodexLogChanges) -> Void) throws {
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
            if let changes = CodexLogChanges.events(root: context.root, paths: paths,
                flags: Array(UnsafeBufferPointer(start: flags, count: count))) {
                context.changed(changes)
            }
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
        var errorDescription: String? { String(localized: "File notifications are unavailable. Automatic log collection has stopped.", bundle: .module) }
    }
}
