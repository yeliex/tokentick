import Foundation

public enum SynchronizationScope: String, Codable, Sendable { case all, local, prices, api, remote }
public enum SynchronizationStage: String, Sendable {
    case scanning, prices, repricing, api, statistics
}
public struct SynchronizationProgress: Sendable {
    public let stage: SynchronizationStage
    public let scan: ScanProgress?
    public init(stage: SynchronizationStage, scan: ScanProgress?) { self.stage = stage; self.scan = scan }
}

public struct SynchronizationReport: Codable, Sendable {
    public let scope: SynchronizationScope
    public let startedAt: Double
    public var finishedAt: Double?
    public var scan: ScanReport?
    public var prices: PriceSyncReport?
    public var reprice: RepriceReport?
    public var api: APISyncReport?
    public var statistics: StatisticsRebuildReport?
    public var issues: [String] = []
}

/// Shared app and CLI synchronization; a source failure does not discard other committed results.
public struct UsageSynchronizer: Sendable {
    public let store: UsageStore
    public init(store: UsageStore) { self.store = store }

    public func synchronize(scope: SynchronizationScope = .all,
                            codexHome: URL = LocalUsageScanner.defaultCodexHome,
                            codexExecutable: URL? = nil,
                            onProgress: (@Sendable (SynchronizationProgress) -> Void)? = nil,
                            onCurrentLimits: (@Sendable (CurrentLimitSnapshot?) async -> Void)? = nil) async throws -> SynchronizationReport {
        let task = Task.detached(priority: .utility) {
            var report = SynchronizationReport(scope: scope, startedAt: Date().timeIntervalSince1970)
            // Fetch and publish current limits before log scanning and statistics finish.
            if scope == .all || scope == .api || scope == .remote {
                onProgress?(SynchronizationProgress(stage: .api, scan: nil))
                do {
                    let result = try await CodexAPIClient.synchronize(store: store, executable: codexExecutable, codexHome: codexHome)
                    report.api = result
                    await onCurrentLimits?(result.currentLimits)
                    if let issue = result.issue { report.issues.append(issue) }
                    if !result.accountAvailable { report.issues.append(String(localized: "The server did not provide a verifiable account identity.", bundle: .module)) }
                } catch {
                    try Task.checkCancellation()
                    report.issues.append(String(localized: "Server: \(error.localizedDescription)", bundle: .module))
                    await onCurrentLimits?(nil)
                }
            }
            try Task.checkCancellation()
            if scope == .all || scope == .local {
                onProgress?(SynchronizationProgress(stage: .scanning, scan: nil))
                do {
                    report.scan = try LocalUsageScanner(store: store).scan(codexHome: codexHome) { progress in
                        onProgress?(SynchronizationProgress(stage: .scanning, scan: progress))
                    }
                    if let count = report.scan?.issueCount, count > 0 { report.issues.append(String(localized: "Log scan issues: \(count). Successfully collected data was kept.", bundle: .module)) }
                } catch {
                    try Task.checkCancellation()
                    report.issues.append(String(localized: "Logs: \(error.localizedDescription)", bundle: .module))
                }
            }
            try Task.checkCancellation()
            if scope == .all || scope == .prices || scope == .remote {
                onProgress?(SynchronizationProgress(stage: .prices, scan: nil))
                do {
                    let prices = try await PriceSynchronizer(store: store).synchronize()
                    report.prices = prices
                } catch {
                    try Task.checkCancellation()
                    report.issues.append(String(localized: "Prices: \(error.localizedDescription)", bundle: .module))
                }
            }
            try Task.checkCancellation()
            // Bundled and stored prices allow repricing even when today's network request fails.
            if scope != .api {
                do {
                    if try store.needsRepricing() {
                        onProgress?(SynchronizationProgress(stage: .repricing, scan: nil))
                        report.reprice = try store.repriceUsage()
                    }
                } catch {
                    try Task.checkCancellation()
                    report.issues.append(String(localized: "Pricing: \(error.localizedDescription)", bundle: .module))
                }
            }
            try Task.checkCancellation()
            onProgress?(SynchronizationProgress(stage: .statistics, scan: nil))
            do { report.statistics = try store.rebuildStatistics() }
            catch { report.issues.append(String(localized: "Statistics: \(error.localizedDescription)", bundle: .module)) }
            try Task.checkCancellation()
            report.finishedAt = Date().timeIntervalSince1970
            try store.saveSynchronizationReport(report)
            return report
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}
