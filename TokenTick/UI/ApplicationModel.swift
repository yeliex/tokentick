import Foundation
import Observation
import TokenTickCore

@MainActor @Observable
final class ApplicationModel {
    @ObservationIgnored private(set) var store: UsageStore?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var automatic: AutomaticSyncController?
    private var started = false
    var isSyncing = false
    var progress: SynchronizationProgress?
    var status: StoreStatus?
    var lastSync: SynchronizationReport?
    var today: UsageSummary?
    var limits: [LimitWindow] = []
    var error: String?
    var refreshID = 0
    var automaticSyncIssue: String?
    var automaticSyncEnabled = UserDefaults.standard.object(forKey: "automaticSyncEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(automaticSyncEnabled, forKey: "automaticSyncEnabled")
            configureAutomaticSync()
        }
    }
    var codexDirectory: String {
        get { UserDefaults.standard.string(forKey: "codexDirectory") ?? LocalUsageScanner.defaultCodexHome.path }
        set {
            UserDefaults.standard.set(newValue, forKey: "codexDirectory")
            configureAutomaticSync()
        }
    }

    var progressText: String {
        guard let progress else { return "准备同步…" }
        switch progress.stage {
        case .scanning:
            if let scan = progress.scan { return "扫描 \(scan.completedFiles)/\(scan.totalFiles) 个文件" }
            return "发现本地日志…"
        case .prices: return "更新模型价格…"
        case .repricing: return "计算分项金额…"
        case .api: return "读取服务端用量…"
        case .statistics: return "更新统计缓存…"
        }
    }

    func start() async {
        guard ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1" else { return }
        guard !started else { return }
        started = true
        do {
            let database = ProcessInfo.processInfo.environment["TOKENTICK_DATABASE"].map { URL(fileURLWithPath: $0) } ?? UsageStore.defaultDatabaseURL
            store = try await Task.detached(priority: .utility) { try UsageStore(databaseURL: database) }.value
            await refresh()
            configureAutomaticSync()
        } catch { self.error = error.localizedDescription; started = false }
    }

    private func configureAutomaticSync() {
        automatic?.stop(); automatic = nil; automaticSyncIssue = nil
        guard store != nil, automaticSyncEnabled, ProcessInfo.processInfo.environment["TOKENTICK_AUTOSYNC"] != "0" else { return }
        let controller = AutomaticSyncController(app: self)
        automatic = controller
        controller.start(home: URL(fileURLWithPath: codexDirectory, isDirectory: true))
    }

    func synchronize(_ scope: SynchronizationScope = .all) {
        guard !isSyncing, let store else { return }
        isSyncing = true
        automatic?.started(scope)
        error = nil
        let home = URL(fileURLWithPath: codexDirectory, isDirectory: true)
        syncTask = Task { [self] in
            defer { isSyncing = false; progress = nil; syncTask = nil; automatic?.finished() }
            do {
                lastSync = try await UsageSynchronizer(store: store).synchronize(scope: scope, codexHome: home) { [weak self] progress in
                    Task { @MainActor in self?.progress = progress }
                }
            } catch is CancellationError { error = "同步已取消，已提交的数据保留。" }
            catch { self.error = error.localizedDescription }
            await refresh()
        }
    }

    func cancelSync() { automatic?.cancelled(); syncTask?.cancel() }

    func refresh() async {
        guard let store else { return }
        do {
            let result = try await Task.detached(priority: .utility) {
                let zone = TimeZone(identifier: try store.statisticsTimezone()) ?? .gmt
                let date = Date().formatted(Date.ISO8601FormatStyle(timeZone: zone).year().month().day().dateSeparator(.dash))
                let today = try store.usageReport(UsageQuery(grouping: .total, fromDate: date, throughDate: date)).rows.first
                return (try store.status(), try store.lastSynchronizationReport(), today, try store.limitWindows(currentOnly: true))
            }.value
            status = result.0
            lastSync = result.1
            today = result.2
            limits = result.3
            refreshID += 1
        } catch { self.error = error.localizedDescription }
    }

    func changeTimezone(_ identifier: String) async {
        guard let store else { return }
        do {
            try await Task.detached(priority: .utility) { try store.setStatisticsTimezone(identifier) }.value
            await refresh()
        } catch { self.error = error.localizedDescription }
    }

    func rebuild() async {
        guard let store, !isSyncing else { return }
        isSyncing = true
        progress = SynchronizationProgress(stage: .statistics, scan: nil)
        defer { isSyncing = false; progress = nil; automatic?.finished() }
        do { _ = try await Task.detached(priority: .utility) { try store.rebuildStatistics() }.value }
        catch { self.error = error.localizedDescription }
        await refresh()
    }
}
