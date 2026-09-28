import CryptoKit
import Foundation

/// Transport reads happen before acquiring the destination writer lock; commits contain only facts and checkpoints.
struct UsageScanner: Sendable {
    private struct CommitFailure: Error { let underlying: any Error }
    let store: UsageStore
    let device: RemoteDevice
    let priority: DevicePriority
    var maximumFilesPerPass = 32
    var maximumBytesPerPass: UInt64 = 64 * 1_024 * 1_024
    var preferIncrementalManifest = false
    var accountID: String? = nil

    func scan(source: any DeviceFileSource, onProgress: (@Sendable (ScanProgress) -> Void)? = nil) async throws -> ScanReport {
        let lock = FileWriteLock(url: store.databaseURL.appendingPathExtension("device-\(device.id).lock"))
        return try await lock.withAsyncLock { try await scanUnlocked(source: source, onProgress: onProgress) }
    }

    private func scanUnlocked(source: any DeviceFileSource, onProgress: (@Sendable (ScanProgress) -> Void)?) async throws -> ScanReport {
        let directories: [String]?
        if preferIncrementalManifest {
            let root = try await source.probe()
            directories = try store.incrementalManifestDirectories(device: device, root: root)
        } else { directories = nil }
        let manifest: DeviceSourceManifest
        if let directories { manifest = try await source.manifest(directories: directories) }
        else {
            // A failed or incomplete full pass must continue full discovery on the next attempt.
            try store.recordFullDeviceManifest(device, at: nil)
            manifest = try await source.manifest()
        }
        var report = ScanReport()
        report.discoveredFiles = manifest.files.count
        // Prefer recent files for useful partial coverage while continuing through all accessible history.
        let plainPaths = Set(manifest.files.filter { $0.rollout?.isCompressed == false }.map(\.path))
        let files = manifest.files.filter {
            $0.rollout != nil && !($0.rollout?.isCompressed == true && plainPaths.contains(String($0.path.dropLast(4))))
        }
        let groups = Dictionary(grouping: files, by: { $0.rollout!.rolloutID }).values
            .map { $0.sorted { $0.path < $1.path } }
            .sorted { ($0.map(\.modifiedAt).max() ?? 0) > ($1.map(\.modifiedAt).max() ?? 0) }
        onProgress?(ScanProgress(completedFiles: 0, totalFiles: groups.count, fileName: "", insertedRequests: 0))
        var lastProgress = ContinuousClock.now
        for (index, copies) in groups.enumerated() {
            try Task.checkCancellation()
            if report.scannedFiles >= maximumFilesPerPass || report.scannedBytes >= maximumBytesPerPass {
                report.pendingFiles = groups.count - index
                break
            }
            let file = copies[0]
            guard let identity = file.rollout else { continue }
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let fingerprint = copies.count == 1 ? "" : SHA256.hash(data: try encoder.encode(copies)).map { String(format: "%02x", $0) }.joined()
                let cursor = try store.scanCursor(rolloutID: identity.rolloutID.uuidString.lowercased(), device: device.id, sourceRevision: device.sourceRevision)
                if copies.count > 1 && cursor?.file.copyFingerprint != fingerprint {
                    var digest: SHA256.Digest?
                    for copy in copies {
                        let reader = try RolloutLineReader(handle: DeviceRolloutFile(source: source, file: copy),
                            compressed: copy.rollout?.isCompressed == true, readSize: 1_048_576)
                        var hash = SHA256()
                        while true {
                            let bytes = try await reader.nextChunk()
                            if bytes.isEmpty { break }
                            hash.update(data: bytes)
                        }
                        let current = hash.finalize()
                        if let digest, digest != current { throw DeviceSourceFailure.conflictingCopies }
                        digest = current
                    }
                }
                let yielded = try await scan(file, identity: identity, root: manifest.root, source: source, fingerprint: fingerprint, report: &report)
                if yielded {
                    report.pendingFiles = groups.count - index
                    onProgress?(ScanProgress(completedFiles: index, totalFiles: groups.count, fileName: identity.fileName,
                                              insertedRequests: report.insertedRequests))
                    break
                }
            }
            catch let error as CommitFailure { throw error.underlying }
            catch {
                try Task.checkCancellation()
                report.addIssue("device_read", ScanIssue(fileName: identity.fileName, line: nil, message: error.localizedDescription))
            }
            if lastProgress.duration(to: .now) >= .milliseconds(200) || index + 1 == groups.count {
                onProgress?(ScanProgress(completedFiles: index + 1, totalFiles: groups.count, fileName: identity.fileName,
                                          insertedRequests: report.insertedRequests))
                lastProgress = .now
            }
        }
        if directories == nil && report.pendingFiles == 0 && report.issueCount == 0 {
            try store.recordFullDeviceManifest(device)
        }
        return report
    }

    private func scan(_ file: DeviceSourceFile, identity: RolloutIdentity, root: String,
                      source: any DeviceFileSource, fingerprint: String, report: inout ScanReport) async throws -> Bool {
        let key = identity.rolloutID.uuidString.lowercased()
        let cursor = try store.scanCursor(rolloutID: key, device: device.id, sourceRevision: device.sourceRevision)
        var snapshot = FileSnapshot(source: file, compressed: identity.isCompressed)
        snapshot.copyFingerprint = fingerprint
        let url = URL(fileURLWithPath: root).appendingPathComponent(file.path)
        if let cursor, cursor.state.version == RolloutParserState.currentVersion,
           cursor.file.copyFingerprint == fingerprint, cursor.file.sameFile(as: snapshot) {
            if cursor.path != url.path {
                try FileWriteLock(url: store.databaseURL.appendingPathExtension("write.lock")).withLock {
                    try store.updateScanPath(rolloutID: key, url: url, device: device.id)
                }
            }
            report.unchangedFiles += 1
            return false
        }
        var scan = RolloutScan(identity: identity, accountID: cursor?.state.accountID ?? accountID)
        if let cursor, cursor.state.version == RolloutParserState.currentVersion,
           !identity.isCompressed, !cursor.file.compressed, cursor.offset > 0,
           cursor.file.sourceIdentity == file.identity, file.size >= cursor.offset,
           file.size > cursor.file.size || (file.size == cursor.file.size && file.modifiedAt == cursor.file.modifiedAt) {
            let count = Int(min(cursor.offset, 4_096))
            if try await hash(source, file, offset: 0, count: count) == cursor.file.prefixHash,
               try await hash(source, file, offset: cursor.offset - UInt64(count), count: count) == cursor.file.tailHash {
                scan = RolloutScan(identity: identity, cursor: cursor, accountID: accountID)
            }
        }
        let initialOffset = scan.offset
        defer { report.scannedBytes += scan.offset - initialOffset }
        let reader = try RolloutLineReader(handle: DeviceRolloutFile(source: source, file: file),
            compressed: identity.isCompressed, offset: scan.offset, readSize: 1_048_576)
        report.scannedFiles += 1
        var completed = true
        while true {
            try Task.checkCancellation()
            // A transport failure must reach device_read/backoff, not masquerade as malformed JSON.
            // Previously committed batches remain resumable; this pending batch is replayed on retry.
            guard let bytes = try await reader.nextLine() else { break }
            do {
                try autoreleasepool { try scan.consume(bytes, endingAt: reader.offset, report: &report) }
            } catch {
                try Task.checkCancellation()
                completed = false
                report.addIssue("parse", ScanIssue(fileName: identity.fileName, line: scan.line + 1, message: error.localizedDescription))
                break
            }
            if scan.batchReady {
                try await commit(&scan, file: file, identity: identity, url: url, source: source,
                                 snapshot: &snapshot, completed: false, report: &report)
                if !identity.isCompressed && report.scannedBytes + scan.offset - initialOffset >= maximumBytesPerPass {
                    report.inheritedEvents += scan.inheritedEvents
                    return true
                }
            }
        }
        try await commit(&scan, file: file, identity: identity, url: url, source: source,
                         snapshot: &snapshot, completed: completed, report: &report)
        report.inheritedEvents += scan.inheritedEvents
        return false
    }

    private func commit(_ scan: inout RolloutScan, file: DeviceSourceFile, identity: RolloutIdentity,
                        url: URL, source: any DeviceFileSource, snapshot: inout FileSnapshot,
                        completed: Bool, report: inout ScanReport) async throws {
        if !identity.isCompressed {
            let count = Int(min(scan.offset, 4_096))
            snapshot.prefixHash = try await hash(source, file, offset: 0, count: count)
            snapshot.tailHash = try await hash(source, file, offset: scan.offset - UInt64(count), count: count)
        }
        snapshot.completed = completed
        do {
            try FileWriteLock(url: store.databaseURL.appendingPathExtension("write.lock")).withLock {
                try scan.commit(store: store, identity: identity, url: url, checkpoint: snapshot,
                            report: &report, device: device.id,
                            sourceRevision: device.sourceRevision, priority: priority)
            }
        } catch { throw CommitFailure(underlying: error) }
    }

    private func hash(_ source: any DeviceFileSource, _ file: DeviceSourceFile, offset: UInt64, count: Int) async throws -> String {
        let data = count == 0 ? Data() : try await source.read(file, offset: offset, count: count)
        guard data.count == count else { throw DeviceSourceFailure.changed }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
