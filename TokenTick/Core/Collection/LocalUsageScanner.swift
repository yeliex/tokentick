import CryptoKit
import Foundation
import Darwin

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
    public var diagnosticCounts: [String: Int] = [:]
    public var diagnosticSamples: [String: ScanIssue] = [:]
    public var currentLimits: CurrentLimitSnapshot? = nil
    private enum CodingKeys: String, CodingKey {
        case discoveredFiles, scannedFiles, unchangedFiles, refreshedThreads, catalogAvailable,
             insertedRequests, upgradedRequests, duplicateRequests, inheritedEvents, scannedBytes, issues, issueCount
    }

    mutating func addIssue(_ reason: String, _ issue: ScanIssue) {
        if reason != "empty_source" {
            diagnosticCounts[reason, default: 0] += 1
            if diagnosticSamples[reason] == nil { diagnosticSamples[reason] = issue }
        }
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
                report.addIssue("fast_evidence", ScanIssue(fileName: "logs_*.sqlite", line: nil, message: String(localized: "Fast evidence: \(error.localizedDescription)", bundle: .module)))
            }
            try store.restoreWeeklyWindows()
            let ordered = try discoverRollouts(codexHome: codexHome, report: &report)
            var lastProgress = ContinuousClock.now
            for (index, copies) in ordered.enumerated() {
                try Task.checkCancellation()
                // Codex prefers the plain file when both representations briefly coexist in a directory.
                // The compressed sibling is not another history; avoid decompressing it just to compare full contents.
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
                guard verifyCopies(sorted, report: &report) else { continue }
                try autoreleasepool { try scanFile(url: url, identity: identity, report: &report) }
            }
            try Task.checkCancellation()
            do {
                if let changed = try ThreadCatalogReader().refresh(codexHome: codexHome, store: store) {
                    report.catalogAvailable = true
                    report.refreshedThreads = changed
                }
            } catch {
                report.addIssue("catalog", ScanIssue(fileName: "state_*.sqlite", line: nil, message: error.localizedDescription))
            }
            try store.saveCompletedWeeklyCycles()
            return report
        }
    }

    private func discoverRollouts(codexHome: URL, report output: inout ScanReport) throws -> [[(URL, RolloutIdentity)]] {
        // Directory enumeration retains its error callback, which cannot capture the caller's inout parameter.
        var report = output
        defer { output = report }
        var candidates: [UUID: [(URL, RolloutIdentity)]] = [:]
        for directory in ["sessions", "archived_sessions"] {
            let root = codexHome.appendingPathComponent(directory, isDirectory: true)
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                                                  options: [.skipsHiddenFiles], errorHandler: { url, error in
                report.addIssue("enumeration", ScanIssue(fileName: url.lastPathComponent, line: nil, message: error.localizedDescription))
                return true
            }) else { continue }
            for case let url as URL in enumerator {
                guard let identity = RolloutIdentity(fileName: url.lastPathComponent) else {
                    let name = url.lastPathComponent
                    if name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") || name.hasSuffix(".jsonl.zst") {
                        report.addIssue("invalid_filename", ScanIssue(fileName: name, line: nil, message: String(localized: "Unable to identify the rollout file. No conversation ID was inferred.", bundle: .module)))
                    }
                    continue
                }
                guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
                candidates[identity.rolloutID, default: []].append((url, identity))
                report.discoveredFiles += 1
            }
        }
        if candidates.isEmpty {
            report.addIssue("empty_source", ScanIssue(fileName: codexHome.lastPathComponent, line: nil, message: String(localized: "No recognizable rollout logs found.", bundle: .module)))
        }
        return candidates.values.sorted { $0[0].1.fileName < $1[0].1.fileName }
    }

    private func verifyCopies(_ sorted: [(URL, RolloutIdentity)], report: inout ScanReport) -> Bool {
        guard sorted.count > 1 else { return true }
        let (url, identity) = sorted[0]
        do {
            let first = try contentDigest(url: url, identity: identity)
            for (otherURL, otherIdentity) in sorted.dropFirst() {
                if try contentDigest(url: otherURL, identity: otherIdentity) != first {
                    report.addIssue("conflicting_copies", ScanIssue(fileName: identity.fileName, line: nil, message: String(localized: "Conflicting copies of this rollout were found. Existing usage was kept and updates to this rollout were stopped.", bundle: .module)))
                    return false
                }
            }
        } catch {
            report.addIssue("copy_read", ScanIssue(fileName: identity.fileName, line: nil, message: error.localizedDescription))
            return false
        }
        return true
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
            report.addIssue("file_read", ScanIssue(fileName: identity.fileName, line: nil, message: error.localizedDescription))
            return
        }
        report.scannedFiles += 1
        let inheritedBefore = parser.inheritedEvents
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
                report.addIssue("parse", ScanIssue(fileName: identity.fileName, line: line + 1,
                                          message: String(localized: "Parsing stopped: \(error.localizedDescription)", bundle: .module)))
                failed = true
                break
            }
            if linesSinceCommit >= 512 {
                try store.commitScan(batch, limits: quotaBatch, identity: identity, url: url, line: line, offset: offset,
                                     file: snapshot, state: &parser.state, completed: false, report: &report)
                batch.removeAll(keepingCapacity: true)
                quotaBatch.removeAll(keepingCapacity: true)
                linesSinceCommit = 0
            }
        }
        try store.commitScan(batch, limits: quotaBatch, identity: identity, url: url, line: line, offset: offset,
                             file: snapshot, state: &parser.state, completed: !failed, report: &report)
        report.scannedBytes += offset - startingOffset
        report.inheritedEvents += parser.inheritedEvents - inheritedBefore
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
