import CryptoKit
import Foundation
import Darwin
import GRDB

public struct ScanReport: Codable, Sendable {
    public var discoveredFiles = 0
    public var scannedFiles = 0
    public var unchangedFiles = 0
    public var refreshedThreads = 0
    public var catalogAvailable = false
    public var insertedRequests = 0
    public var upgradedRequests = 0
    public var duplicateRequests = 0
    public var inheritedEvents = 0
    public var scannedBytes: UInt64 = 0
    public var issues: [ScanIssue] = []
    public var issueCount = 0
    public var currentLimits: CurrentLimitSnapshot? = nil
    private enum CodingKeys: String, CodingKey {
        case discoveredFiles, scannedFiles, unchangedFiles, refreshedThreads, catalogAvailable,
             insertedRequests, upgradedRequests, duplicateRequests, inheritedEvents, scannedBytes, issues, issueCount
    }

    mutating func addIssue(_ issue: ScanIssue) {
        issueCount += 1
        if issues.count < 100 { issues.append(issue) }
    }
}

public struct ScanIssue: Codable, Sendable {
    public let fileName: String
    public let line: Int?
    public let message: String
}

public struct ScanProgress: Sendable {
    public let completedFiles: Int
    public let totalFiles: Int
    public let fileName: String
    public let insertedRequests: Int
}

public struct LocalUsageScanner: Sendable {
    public let store: UsageStore
    public init(store: UsageStore) { self.store = store }

    public static var defaultCodexHome: URL {
        if let value = getenv("CODEX_HOME"), !String(cString: value).isEmpty {
            let configured = (String(cString: value) as NSString).expandingTildeInPath
            return URL(fileURLWithPath: configured, isDirectory: true).standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    public func scan(codexHome: URL = LocalUsageScanner.defaultCodexHome,
                     onProgress: (@Sendable (ScanProgress) -> Void)? = nil) throws -> ScanReport {
        try FileWriteLock(url: store.databaseURL.appendingPathExtension("write.lock")).withLock {
            var report = ScanReport()
            do { try CodexFastEvidence.collect(codexHome: codexHome, store: store) }
            catch {
                try Task.checkCancellation()
                report.addIssue(ScanIssue(fileName: "logs_*.sqlite", line: nil, message: "Fast 证据：\(error.localizedDescription)"))
            }
            var candidates: [UUID: [(URL, RolloutIdentity)]] = [:]
            for directory in ["sessions", "archived_sessions"] {
                let root = codexHome.appendingPathComponent(directory, isDirectory: true)
                guard FileManager.default.fileExists(atPath: root.path) else { continue }
                guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                                                      options: [.skipsHiddenFiles], errorHandler: { url, error in
                    report.addIssue(ScanIssue(fileName: url.lastPathComponent, line: nil, message: error.localizedDescription))
                    return true
                }) else { continue }
                for case let url as URL in enumerator {
                    guard let identity = RolloutIdentity(fileName: url.lastPathComponent) else {
                        let name = url.lastPathComponent
                        if name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") || name.hasSuffix(".jsonl.zst") {
                            report.addIssue(ScanIssue(fileName: name, line: nil, message: "无法识别 rollout 文件身份，未猜测对话 ID。"))
                        }
                        continue
                    }
                    guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
                    candidates[identity.rolloutID, default: []].append((url, identity))
                    report.discoveredFiles += 1
                }
            }
            if candidates.isEmpty {
                report.addIssue(ScanIssue(fileName: codexHome.lastPathComponent, line: nil, message: "未发现可识别的 rollout 日志。"))
            }
            let ordered = candidates.values.sorted { $0[0].1.fileName < $1[0].1.fileName }
            var lastProgress = ContinuousClock.now
            for (index, copies) in ordered.enumerated() {
                try Task.checkCancellation()
                // Codex 在表示转换时允许同目录短暂并存，并优先使用普通文件。
                // 压缩兄弟文件不是另一份历史，不为它重复解压和比较全文。
                let plainPaths = Set(copies.filter { !$0.1.isCompressed }.map { $0.0.path })
                let sorted = copies.filter { url, identity in
                    !identity.isCompressed || !plainPaths.contains(url.deletingPathExtension().path)
                }.sorted { $0.0.path < $1.0.path }
                let (url, identity) = sorted[0]
                defer {
                    if lastProgress.duration(to: .now) >= .milliseconds(200) || index + 1 == ordered.count {
                        onProgress?(ScanProgress(completedFiles: index + 1, totalFiles: ordered.count,
                                                 fileName: identity.fileName, insertedRequests: report.insertedRequests))
                        lastProgress = .now
                    }
                }
                if sorted.count > 1 {
                    do {
                        let first = try contentDigest(url: url, identity: identity)
                        var conflict = false
                        for (otherURL, otherIdentity) in sorted.dropFirst() {
                            if try contentDigest(url: otherURL, identity: otherIdentity) != first { conflict = true; break }
                        }
                        if conflict {
                            report.addIssue(ScanIssue(fileName: identity.fileName, line: nil, message: "同一 rollout 的多份文件内容不一致，已保留原有用量并停止更新该 rollout。"))
                            continue
                        }
                    } catch {
                        report.addIssue(ScanIssue(fileName: identity.fileName, line: nil, message: error.localizedDescription))
                        continue
                    }
                }
                try autoreleasepool { try scanFile(url: url, identity: identity, report: &report) }
            }
            try Task.checkCancellation()
            do {
                if let changed = try ThreadCatalogReader().refresh(codexHome: codexHome, store: store) {
                    report.catalogAvailable = true
                    report.refreshedThreads = changed
                }
            } catch {
                report.addIssue(ScanIssue(fileName: "state_*.sqlite", line: nil, message: error.localizedDescription))
            }
            return report
        }
    }

    private func scanFile(url: URL, identity: RolloutIdentity, report: inout ScanReport) throws {
        let key = identity.rolloutID.uuidString.lowercased()
        let cursor = try store.scanCursor(rolloutID: key)
        let snapshot: FileSnapshot
        let reader: RolloutLineReader
        var parser = RolloutParser(state: RolloutParserState(), identity: identity)
        var line = 0
        var offset: UInt64 = 0
        do {
            snapshot = try FileSnapshot(url: url, compressed: identity.isCompressed)
            if let cursor, cursor.state.version == RolloutParserState.currentVersion,
               cursor.file.sameFile(as: snapshot) {
                try store.updateScanPath(rolloutID: key, url: url)
                report.unchangedFiles += 1
                return
            }
            if let cursor, cursor.state.version == RolloutParserState.currentVersion,
               try cursor.file.canResume(url: url, snapshot: snapshot, offset: cursor.offset) {
                parser.state = cursor.state
                line = cursor.line
                offset = cursor.offset
            }
            reader = try RolloutLineReader(url: url, compressed: identity.isCompressed, offset: offset)
        } catch {
            report.addIssue(ScanIssue(fileName: identity.fileName, line: nil, message: error.localizedDescription))
            return
        }
        report.scannedFiles += 1
        let inheritedBefore = parser.state.inheritedEvents
        let startingOffset = offset
        var batch: [CollectedUsage] = []
        var quotaBatch: [CurrentLimitSnapshot] = []
        var linesSinceCommit = 0
        var failed = false
        while true {
            if linesSinceCommit == 0 { try Task.checkCancellation() }
            let previousState = parser.state
            do {
                let hasLine = try autoreleasepool {
                    guard let data = try reader.nextLine() else { return false }
                    if let usage = try parser.consume(data, line: line + 1) { batch.append(usage) }
                    if let limits = parser.currentLimits {
                        if limits.windows.contains(where: { $0.durationMinutes == 10_080 }) { quotaBatch.append(limits) }
                        if limits.historyExclusion == nil, report.currentLimits.map({ limits.observedAt > $0.observedAt }) ?? true { report.currentLimits = limits }
                    }
                    line += 1
                    offset = reader.offset
                    linesSinceCommit += 1
                    return true
                }
                if !hasLine { break }
            } catch {
                parser.state = previousState
                report.addIssue(ScanIssue(fileName: identity.fileName, line: line + 1,
                                          message: "解析停止：\(error.localizedDescription)"))
                failed = true
                break
            }
            if linesSinceCommit >= 512 {
                try store.commitScan(batch, limits: quotaBatch, identity: identity, url: url, line: line, offset: offset,
                                     file: snapshot, state: parser.state, completed: false, report: &report)
                batch.removeAll(keepingCapacity: true)
                quotaBatch.removeAll(keepingCapacity: true)
                linesSinceCommit = 0
            }
        }
        try store.commitScan(batch, limits: quotaBatch, identity: identity, url: url, line: line, offset: offset,
                             file: snapshot, state: parser.state, completed: !failed, report: &report)
        report.scannedBytes += offset - startingOffset
        report.inheritedEvents += parser.state.inheritedEvents - inheritedBefore
    }

    private func contentDigest(url: URL, identity: RolloutIdentity) throws -> String {
        let reader = try RolloutLineReader(url: url, compressed: identity.isCompressed)
        var hash = SHA256()
        while try autoreleasepool(invoking: {
            try Task.checkCancellation()
            let chunk = try reader.nextChunk()
            if chunk.isEmpty { return false }
            hash.update(data: chunk)
            return true
        }) {}
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

struct ScanCursor {
    let line: Int
    let offset: UInt64
    let file: FileSnapshot
    let state: RolloutParserState
}

struct FileSnapshot: Codable {
    let size: UInt64
    let modifiedAt: TimeInterval
    let inode: UInt64
    let device: UInt64
    let compressed: Bool
    var completed = false
    var prefixCount = 0
    var prefixHash = ""
    var tailHash = ""

    init(url: URL, compressed: Bool) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        modifiedAt = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        device = (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0
        self.compressed = compressed
    }

    func sameFile(as other: Self) -> Bool {
        completed && size == other.size && modifiedAt == other.modifiedAt
            && inode == other.inode && device == other.device && compressed == other.compressed
    }

    func canResume(url: URL, snapshot: Self, offset: UInt64) throws -> Bool {
        guard !compressed, !snapshot.compressed, offset > 0, snapshot.size >= offset,
              inode == snapshot.inode, device == snapshot.device,
              snapshot.size > size || (snapshot.size == size && snapshot.modifiedAt == modifiedAt) else { return false }
        return try Self.hash(url: url, offset: 0, count: prefixCount) == prefixHash
            && Self.hash(url: url, offset: offset - min(offset, 4_096), count: Int(min(offset, 4_096))) == tailHash
    }

    static func hash(url: URL, offset: UInt64, count: Int) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: count) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
