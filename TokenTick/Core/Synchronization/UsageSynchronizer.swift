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

/// App 和 CLI 共用的同步入口，各来源失败互不抹除已完成的采集。
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
            // 当前额度先获取并立即发布，不等待日志扫描和统计完成。
            if scope == .all || scope == .api || scope == .remote {
                onProgress?(SynchronizationProgress(stage: .api, scan: nil))
                do {
                    let result = try await CodexAPIClient.synchronize(store: store, executable: codexExecutable, codexHome: codexHome)
                    report.api = result
                    await onCurrentLimits?(result.currentLimits)
                    if let issue = result.issue { report.issues.append(issue) }
                    if !result.accountAvailable { report.issues.append("服务端未提供可确认的账号归属。") }
                } catch {
                    try Task.checkCancellation()
                    report.issues.append("服务端：\(error.localizedDescription)")
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
                    if let count = report.scan?.issueCount, count > 0 { report.issues.append("日志扫描发现 \(count) 个问题，已保留成功采集的数据。") }
                } catch {
                    try Task.checkCancellation()
                    report.issues.append("日志：\(error.localizedDescription)")
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
                    report.issues.append("价格：\(error.localizedDescription)")
                }
            }
            try Task.checkCancellation()
            // 内置价格和已存历史也能重算，不依赖当天网络请求成功。
            if scope != .api {
                do {
                    if try store.needsRepricing() {
                        onProgress?(SynchronizationProgress(stage: .repricing, scan: nil))
                        report.reprice = try store.repriceUsage()
                    }
                } catch {
                    try Task.checkCancellation()
                    report.issues.append("计价：\(error.localizedDescription)")
                }
            }
            try Task.checkCancellation()
            onProgress?(SynchronizationProgress(stage: .statistics, scan: nil))
            do { report.statistics = try store.rebuildStatistics() }
            catch { report.issues.append("统计：\(error.localizedDescription)") }
            try Task.checkCancellation()
            report.finishedAt = Date().timeIntervalSince1970
            try store.saveSynchronizationReport(report)
            return report
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}
