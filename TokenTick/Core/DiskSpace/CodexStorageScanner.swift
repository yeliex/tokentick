import Foundation

public enum CodexStorageCategory: String, CaseIterable, Codable, Sendable, Identifiable {
    case conversations, worktrees, logs, plugins, generatedContent, projectless, other
    public var id: Self { self }

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        let name = try value.decode(String.self)
        // Keep snapshots from before generated images and visualizations were combined.
        if name == "visualizations" { self = .generatedContent }
        else if let category = Self(rawValue: name) { self = category }
        else { throw DecodingError.dataCorruptedError(in: value, debugDescription: "Unknown storage category: \(name)") }
    }

    static func classify(_ name: String) -> Self {
        switch name {
        case "sessions", "archived_sessions": .conversations
        case "worktrees": .worktrees
        case "visualizations", "generated_images": .generatedContent
        case "log", "logs": .logs
        case "plugins", "skills", "skills.disabled": .plugins
        default: name.hasPrefix("logs_") && name.contains(".sqlite") ? .logs : .other
        }
    }
}

public struct CodexStorageEntry: Identifiable, Codable, Sendable {
    public let url: URL
    public let isDirectory: Bool
    public var allocatedBytes: Int64 = 0
    public var incomplete = false
    public var children: [CodexStorageEntry] = []
    public var id: String { url.path }
}

public struct CodexStorageGroup: Identifiable, Codable, Sendable {
    public let category: CodexStorageCategory
    public let entries: [CodexStorageEntry]
    public var id: CodexStorageCategory { category }
    public var allocatedBytes: Int64 { entries.reduce(0) { $0 + $1.allocatedBytes } }
    public var incomplete: Bool { entries.contains { $0.incomplete } }
}

public struct CodexStorageSnapshot: Codable, Sendable {
    public let root: URL
    public let projectlessRoot: URL?
    public let startedAt: Date
    public let finishedAt: Date
    public let groups: [CodexStorageGroup]
    public let issueCount: Int
    public let issues: [String]
    public var allocatedBytes: Int64 { groups.reduce(0) { $0 + $1.allocatedBytes } }
}

public enum CodexStorageScanner {
    public static func projectlessRoot(for root: URL, userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        let fallback = userHome.appendingPathComponent("Documents/Codex")
        guard let config = try? String(contentsOf: root.appendingPathComponent("config.toml"), encoding: .utf8) else { return fallback.resolvingSymlinksInPath() }
        var desktop = false
        for line in config.components(separatedBy: .newlines) {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { desktop = line == "[desktop]"; continue }
            guard desktop, let match = line.firstMatch(of: /^projectlessWorkspaceRoot\s*=\s*("(?:[^"\\]|\\.)*"|'[^']*')/) else { continue }
            let raw = String(match.1)
            let path = raw.hasPrefix("'") ? String(raw.dropFirst().dropLast()) : (try? JSONDecoder().decode(String.self, from: Data(raw.utf8)))
            guard let path, !path.isEmpty else { continue }
            let expanded = path == "~" ? userHome.path : path.hasPrefix("~/") ? userHome.appendingPathComponent(String(path.dropFirst(2))).path : path
            guard expanded.hasPrefix("/") else { continue }
            return URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath()
        }
        return fallback.resolvingSymlinksInPath()
    }

    public static func scan(root: URL, projectlessDirectory: URL? = nil,
                            onDiagnostic: (@Sendable (SynchronizationDiagnostic) -> Void)? = nil,
                            onProgress: (@Sendable (CodexStorageSnapshot) async -> Void)? = nil) async throws -> CodexStorageSnapshot {
        try Task.checkCancellation()
        let started = Date()
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let projectless = (projectlessDirectory ?? projectlessRoot(for: root)).standardizedFileURL.resolvingSymlinksInPath()
        var urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                .map { $0.standardizedFileURL }.sorted { $0.path < $1.path }
        } catch {
            let nsError = error as NSError
            if !(nsError.domain == NSCocoaErrorDomain && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(nsError.code)) {
                onDiagnostic?(SynchronizationDiagnostic(error: error, operation: "storage.enumerate", warning: true))
            }
            urls = []
        }
        // Include the external task folder in the same system scan. A missing folder uses zero bytes.
        if projectless != root, !urls.contains(projectless), FileManager.default.fileExists(atPath: projectless.path) {
            urls.append(projectless)
        }
        var entries: [String: CodexStorageEntry] = [:]
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            entries[url.path] = CodexStorageEntry(url: url, isDirectory: values?.isDirectory == true && values?.isSymbolicLink != true,
                                                incomplete: false)
        }
        var issues: [String] = []
        var issueCount = 0
        var completed: Set<String> = []
        var lastProgress: ContinuousClock.Instant?
        if !urls.isEmpty {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
            process.arguments = ["-k", "-P", "-d", "1"] + urls.map(\.path)
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try process.run()
                try pipe.fileHandleForWriting.close()
                defer {
                    if process.isRunning { process.terminate() }
                    process.waitUntilExit()
                    try? pipe.fileHandleForReading.close()
                }
                var pending = Data()
                while true {
                    try Task.checkCancellation()
                    let chunk = pipe.fileHandleForReading.availableData
                    pending.append(chunk)
                    // Decode complete lines so pipe reads cannot split a UTF-8 path.
                    while let newline = pending.firstIndex(of: 10) ?? (chunk.isEmpty && !pending.isEmpty ? pending.endIndex : nil) {
                        let line = String(decoding: pending[..<newline], as: UTF8.self)
                        pending.removeSubrange(pending.startIndex..<(newline == pending.endIndex ? newline : pending.index(after: newline)))
                        try Task.checkCancellation()
                        let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                        guard fields.count == 2, let blocks = Int64(fields[0]), blocks >= 0, blocks <= Int64.max / 1024 else {
                            issueCount += 1
                            if issues.count < 20 { issues.append(line) }
                            continue
                        }
                        let path = String(fields[1])
                        let bytes = blocks * 1024
                        if entries[path] != nil {
                            entries[path]?.allocatedBytes = bytes
                            completed.insert(path)
                        } else {
                            let url = URL(fileURLWithPath: path)
                            let parent = url.deletingLastPathComponent().path
                            entries[parent]?.children.append(CodexStorageEntry(url: url, isDirectory: true, allocatedBytes: bytes))
                        }
                    }
                    if !chunk.isEmpty, let onProgress, lastProgress.map({ $0.duration(to: .now) >= .milliseconds(200) }) ?? true {
                        await onProgress(snapshot(root: root, projectless: projectless, started: started,
                            entries: entries, completed: completed, issueCount: issueCount, issues: issues, scanning: true))
                        lastProgress = .now
                    }
                    if chunk.isEmpty { break }
                }
                process.waitUntilExit()
                try Task.checkCancellation()
            } onCancel: {
                if process.isRunning { process.terminate() }
            }
            if process.terminationStatus != 0 && issueCount == 0 { issueCount = 1 }
            if issueCount > 0 {
                onDiagnostic?(SynchronizationDiagnostic(operation: "storage.scan", reason: "partial_scan",
                    code: Int(process.terminationStatus), count: issueCount, warning: true))
            }
        }
        try Task.checkCancellation()
        return snapshot(root: root, projectless: projectless, started: started, entries: entries,
                        completed: completed, issueCount: issueCount, issues: issues, scanning: false)
    }

    private static func snapshot(root: URL, projectless: URL, started: Date,
                                 entries: [String: CodexStorageEntry], completed: Set<String>,
                                 issueCount: Int, issues: [String], scanning: Bool) -> CodexStorageSnapshot {
        var entries = entries
        // Until du emits a parent's total, its completed children provide a lower bound.
        for path in entries.keys where !completed.contains(path) {
            let bytes = entries[path]?.children.reduce(0) { $0 + $1.allocatedBytes } ?? 0
            entries[path]?.allocatedBytes = bytes
        }
        // When configured inside CODEX_HOME, move its bytes out of the containing category.
        if let taskEntry = entries[projectless.path], projectless.path.hasPrefix(root.path + "/") {
            for path in Array(entries.keys) where path != projectless.path && projectless.path.hasPrefix(path + "/") && completed.contains(path) {
                let remaining = max(0, (entries[path]?.allocatedBytes ?? 0) - taskEntry.allocatedBytes)
                entries[path]?.allocatedBytes = remaining
                entries[path]?.children.removeAll { $0.url == projectless }
            }
        }
        var grouped: [CodexStorageCategory: [CodexStorageEntry]] = [:]
        for var entry in entries.values {
            entry.incomplete = issueCount > 0 || (scanning && !completed.contains(entry.url.path))
            entry.children.sort { scanning ? $0.id < $1.id : largerFirst($0, $1) }
            if entry.url != projectless && CodexStorageCategory.classify(entry.url.lastPathComponent) != .worktrees { entry.children = [] }
            grouped[entry.url == projectless ? .projectless : CodexStorageCategory.classify(entry.url.lastPathComponent), default: []].append(entry)
        }
        var groups: [CodexStorageGroup] = []
        for category in CodexStorageCategory.allCases {
            groups.append(CodexStorageGroup(category: category, entries: (grouped[category] ?? []).sorted { scanning ? $0.id < $1.id : largerFirst($0, $1) }))
        }
        if !scanning {
            groups.sort {
                if $0.category == .other { return false }
                if $1.category == .other { return true }
                if $0.allocatedBytes == $1.allocatedBytes { return $0.category.rawValue < $1.category.rawValue }
                return $0.allocatedBytes > $1.allocatedBytes
            }
        }
        return CodexStorageSnapshot(root: root, projectlessRoot: projectless, startedAt: started, finishedAt: Date(), groups: groups,
                                    issueCount: issueCount, issues: issues)
    }

    private static func largerFirst(_ lhs: CodexStorageEntry, _ rhs: CodexStorageEntry) -> Bool {
        lhs.allocatedBytes == rhs.allocatedBytes ? lhs.id < rhs.id : lhs.allocatedBytes > rhs.allocatedBytes
    }
}
