import Foundation

public struct DeviceSyncResult: Codable, Sendable {
    public let deviceID: String
    public let root: String
    public let scan: ScanReport?
    public let finishedAt: Date
    public var accountEmail: String?
    public let metadataRefreshed: Bool
    public var dataChanged = false
}

public struct DeviceConnectionTestResult: Sendable {
    public let root: String
    public let accountEmail: String?
}

/// Share the source lifecycle between Settings and scheduled collection.
public struct DeviceSyncService: Sendable {
    public let store: UsageStore
    public let executable: URL
    public let configurations: DeviceConfigurationStore
    private var sshConfiguration: URL?

    public init(store: UsageStore, executable: URL) {
        self.store = store
        self.executable = executable
        let directory = store.databaseURL.deletingLastPathComponent()
        configurations = DeviceConfigurationStore(directory: directory)

    }

    init(store: UsageStore, executable: URL, sshConfiguration: URL) {
        self.init(store: store, executable: executable)
        self.sshConfiguration = sshConfiguration
    }

    public func validateDirectory(_ device: RemoteDevice) async throws {
        guard case .directory(let path, let bookmark) = device.connection else { return }
        let url: URL
        if let bookmark {
            var stale = false
            url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &stale)
        } else { url = URL(fileURLWithPath: path) }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let source = DirectoryDeviceSource(root: url, executable: executable)
        do {
            _ = try await source.probe()
            await source.close()
        } catch {
            await source.close()
            throw error
        }
    }

    func synchronizeLocal(codexHome: URL, onProgress: (@Sendable (ScanProgress) -> Void)?) async throws -> ScanReport {
        let result = try await synchronize(.local(root: codexHome), refreshMetadata: true, onProgress: onProgress)
        guard let scan = result.scan else { throw DeviceSourceFailure.invalidResponse }
        return scan
    }

    public func test(_ device: RemoteDevice) async throws -> DeviceConnectionTestResult {
        // Unsaved edits must not read credentials from the saved device configuration.
        var draftDirectory: URL?
        defer { if let draftDirectory { try? FileManager.default.removeItem(at: draftDirectory) } }
        if let address = device.address, try ParsedDeviceConnection(address: address).password != nil {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            draftDirectory = directory
            var draft = device
            if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { draft.name = "Connection test" }
            try DeviceConfigurationStore(directory: directory).update { $0.devices = [draft] }
        }
        return try await withSource(device, configurationDirectory: draftDirectory) { source in
            let root = try await source.probe()
            let email = try? await (source as? any DeviceAccountSource)?.accountEmail()
            try Task.checkCancellation()
            return DeviceConnectionTestResult(root: root, accountEmail: email)
        }
    }

    public func synchronize(_ device: RemoteDevice, refreshMetadata: Bool = true, onProgress: (@Sendable (ScanProgress) -> Void)? = nil) async throws -> DeviceSyncResult {
        try await CollectionScheduler.shared.run(key: store.databaseURL.standardizedFileURL.path + ":" + device.id) {
            try await withSource(device) { source in
                try await collectSource(device, source: source, refreshMetadata: refreshMetadata, onProgress: onProgress)
            }
        }
    }

    private func withSource<Result: Sendable>(_ device: RemoteDevice, configurationDirectory: URL? = nil,
        operation: @Sendable (any DeviceFileSource) async throws -> Result) async throws -> Result {
        let source: any DeviceFileSource
        var scopedURL: URL?
        switch device.connection {
        case .directory(let path, let bookmark):
            let url: URL
            if let bookmark {
                var stale = false
                url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &stale)
            } else { url = URL(fileURLWithPath: path) }
            if url.startAccessingSecurityScopedResource() { scopedURL = url }
            source = device.id == "local" ? try LocalFileSource(root: url) : DirectoryDeviceSource(root: url, executable: executable)
        case .ssh:
            source = try await SSHDeviceSource(device: device, executable: executable,
                configurationDirectory: configurationDirectory ?? configurations.url.deletingLastPathComponent(), sshConfiguration: sshConfiguration)
        }
        defer { scopedURL?.stopAccessingSecurityScopedResource() }
        do {
            let result = try await operation(source)
            await source.close()
            return result
        } catch {
            await source.close()
            throw error
        }
    }

    private func collectSource(_ device: RemoteDevice, source: any DeviceFileSource, refreshMetadata: Bool,
        onProgress: (@Sendable (ScanProgress) -> Void)?) async throws -> DeviceSyncResult {
        let root = try await source.probe()
        let previousRevision = try await store.pool.read { try UsageStore.statisticsRevision($0) }
        var completedCycles = 0
        var metadataRefreshed = false
        let configuration = device.id == "local" ? DeviceConfiguration() : try configurations.load()
        let priority = DevicePriority(devices: configuration.devices)
        try FileWriteLock(url: store.databaseURL.appendingPathExtension("write.lock")).withLock {
            try store.restoreWeeklyWindows()
        }
        var report = try await UsageScanner(store: store, device: device, priority: priority,
            maximumFilesPerPass: device.id == "local" ? .max : 32,
            maximumBytesPerPass: device.id == "local" ? .max : 64 * 1_024 * 1_024,
            preferIncrementalManifest: !refreshMetadata)
            .scan(source: source, onProgress: onProgress)
        let catalogPending = try store.deviceCatalogCursor(device: device.id, sourceRevision: device.sourceRevision) != nil
        let shouldRefreshMetadata = refreshMetadata || report.scannedFiles > 0 || catalogPending
        if let traces = source as? any DeviceTraceSource {
            do {
                for file in try await traces.traceFiles() {
                    let key = "fast_trace_cursor:\(device.id):\(device.sourceRevision):\(file)"
                    var cursor = try store.fastEvidenceCursor(key: key)
                    var pages = 0
                    while true {
                        let page = try await traces.tracePage(file: file, cursor: cursor)
                        try Task.checkCancellation()
                        let evidence = page.entries.compactMap {
                            CodexFastEvidence.parse(body: $0.body, threadID: $0.threadID, fileName: file,
                                rowID: $0.id, timestamp: $0.timestamp)
                        }
                        try FileWriteLock(url: store.databaseURL.appendingPathExtension("write.lock")).withLock {
                            try store.commitFastEvidence(evidence, cursor: page.cursor, key: key)
                        }
                        pages += 1
                        guard page.hasMore else { break }
                        guard page.cursor != cursor else { throw DeviceSourceFailure.invalidResponse }
                        cursor = page.cursor
                        if device.id != "local", pages == 32 { report.pendingMetadata = true; break }
                    }
                }
            } catch {
                try Task.checkCancellation()
                report.addIssue(device.id == "local" ? "fast_evidence" : "traces", ScanIssue(fileName: "logs_*.sqlite", line: nil, message: error.localizedDescription))
            }
        }
        if shouldRefreshMetadata {
            do {
                try await DeviceCatalogCollector(store: store, device: device,
                    maximumPages: device.id == "local" ? .max : 32)
                    .collect(source: source, report: &report)
                metadataRefreshed = !report.pendingMetadata
            } catch {
                try Task.checkCancellation()
                report.addIssue("catalog", ScanIssue(fileName: "state_*.sqlite", line: nil, message: error.localizedDescription))
            }
        }
        try FileWriteLock(url: store.databaseURL.appendingPathExtension("write.lock")).withLock {
            completedCycles = try store.saveCompletedWeeklyCycles()
        }
        // Optional identity failure must not discard collected facts or borrow the local login.
        let email = metadataRefreshed ? try? await (source as? any DeviceAccountSource)?.accountEmail() : nil
        try Task.checkCancellation()
        if device.id != "local", report.issueCount == 0, report.pendingFiles == 0, !report.pendingMetadata {
            try store.recordDeviceCollectionComplete(device)
        }
        let revision = try await store.pool.read { try UsageStore.statisticsRevision($0) }
        return DeviceSyncResult(deviceID: device.id, root: root, scan: report, finishedAt: Date(), accountEmail: email, metadataRefreshed: metadataRefreshed,
            dataChanged: revision != previousRevision || completedCycles > 0 || report.scannedFiles > 0)
    }
}
