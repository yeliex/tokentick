import Foundation

public struct ScanReport: Codable, Sendable {
    public var discoveredFiles = 0
    public var scannedFiles = 0
    public var unchangedFiles = 0
    public var pendingFiles = 0
    public var pendingMetadata = false
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
        case discoveredFiles, scannedFiles, unchangedFiles, pendingFiles, pendingMetadata, refreshedThreads, catalogAvailable,
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
                     onProgress: (@Sendable (ScanProgress) -> Void)? = nil) async throws -> ScanReport {
        try await DeviceSyncService(store: store, executable: Bundle.main.executableURL!)
            .synchronizeLocal(codexHome: codexHome, onProgress: onProgress)
    }
}
