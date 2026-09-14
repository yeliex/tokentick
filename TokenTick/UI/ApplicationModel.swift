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
    var limitSession = CurrentLimitSession()
    var currentLimits: CurrentLimitSnapshot? { limitSession.snapshot }
    @ObservationIgnored private var loginMonitor: Task<Void, Never>?
    @ObservationIgnored private var loginStamp: LoginStamp?
    var error: String?
    var refreshID = 0
    var usageRefreshID = 0
    var settingsSection = "通用"
    var automaticSyncIssue: String?
    var automaticSyncEnabled = UserDefaults.standard.object(forKey: "automaticSyncEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(automaticSyncEnabled, forKey: "automaticSyncEnabled")
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
            checkLoginEnvironment()
            monitorLoginEnvironment()
            configureAutomaticSync()
        } catch { self.error = error.localizedDescription; started = false }
    }

    private func configureAutomaticSync() {
        automatic?.stop(); automatic = nil; automaticSyncIssue = nil
        guard store != nil, automaticSyncEnabled, ProcessInfo.processInfo.environment["TOKENTICK_AUTOSYNC"] != "0" else { return }
        let controller = AutomaticSyncController(app: self)
        automatic = controller
        controller.start()
    }

    func synchronize(_ scope: SynchronizationScope = .all) {
        guard !isSyncing, let store else { return }
        checkLoginEnvironment()
        let limitGeneration = limitSession.generation
        isSyncing = true
        automatic?.started(scope)
        error = nil
        let home = LocalUsageScanner.defaultCodexHome
        syncTask = Task { [self] in
            defer { isSyncing = false; progress = nil; syncTask = nil; automatic?.finished() }
            do {
                lastSync = try await UsageSynchronizer(store: store).synchronize(scope: scope, codexHome: home) { [weak self] progress in
                    Task { @MainActor in self?.progress = progress }
                }
                checkLoginEnvironment()
                if scope == .all || scope == .api || scope == .remote {
                    limitSession.acceptAPI(lastSync?.api?.currentLimits, generation: limitGeneration,
                                           now: Date().timeIntervalSince1970)
                }
                if limitSession.acceptLog(lastSync?.scan?.currentLimits, generation: limitGeneration,
                                          now: Date().timeIntervalSince1970),
                   let log = lastSync?.scan?.currentLimits {
                    let main = currentLimits?.windows.filter { $0.limitID == "codex" } ?? []
                    if !main.isEmpty, main.allSatisfy({ window in log.windows.contains { $0.id == window.id } }) {
                        automatic?.acceptedLog(observedAt: log.observedAt)
                    }
                }
            } catch is CancellationError { error = "同步已取消，已提交的数据保留。" }
            catch {
                self.error = error.localizedDescription
                if scope == .all || scope == .api || scope == .remote {
                    limitSession.acceptAPI(nil, generation: limitGeneration, now: Date().timeIntervalSince1970)
                }
            }
            await refresh()
        }
    }

    func cancelSync() { automatic?.cancelled(); syncTask?.cancel() }

    private struct LoginStamp: Equatable {
        let home: String
        let modified: Date?
        let size: UInt64?
        let inode: UInt64?
    }

    @discardableResult private func checkLoginEnvironment() -> Bool {
        let home = LocalUsageScanner.defaultCodexHome
        // 仅检查认证文件元数据，不读取、复制或保存凭据内容。
        let attributes = try? FileManager.default.attributesOfItem(atPath: home.appendingPathComponent("auth.json").path)
        let stamp = LoginStamp(home: home.path, modified: attributes?[.modificationDate] as? Date,
                              size: attributes?[.size] as? UInt64, inode: attributes?[.systemFileNumber] as? UInt64)
        guard stamp != loginStamp else { return false }
        loginStamp = stamp
        limitSession.invalidate()
        return true
    }

    private func monitorLoginEnvironment() {
        loginMonitor?.cancel()
        loginMonitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self else { return }
                if self.checkLoginEnvironment(), self.automaticSyncEnabled,
                   ProcessInfo.processInfo.environment["TOKENTICK_AUTOSYNC"] != "0", !self.isSyncing {
                    self.synchronize(.api)
                }
            }
        }
    }

    func refresh() async {
        guard let store else { return }
        do {
            let result = try await Task.detached(priority: .utility) {
                let zone = TimeZone(identifier: try store.statisticsTimezone()) ?? .gmt
                let date = Date().formatted(Date.ISO8601FormatStyle(timeZone: zone).year().month().day().dateSeparator(.dash))
                let today = try store.usageReport(UsageQuery(grouping: .total, fromDate: date, throughDate: date)).rows.first
                let status = try store.status()
                return (status, try store.lastSynchronizationReport(), today)
            }.value
            if status?.factsRevision != result.0.factsRevision || status?.timezone != result.0.timezone { usageRefreshID += 1 }
            status = result.0
            lastSync = result.1
            if today != result.2 { today = result.2 }
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
