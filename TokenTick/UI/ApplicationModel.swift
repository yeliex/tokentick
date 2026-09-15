import Foundation
import Observation
import TokenTickCore

@MainActor @Observable
final class ApplicationModel {
    private(set) var store: UsageStore?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var automatic: AutomaticSyncController?
    private var started = false
    var requestedPage: AppPage?
    var isSyncing = false
    var progress: SynchronizationProgress?
    var status: StoreStatus?
    var lastSync: SynchronizationReport?
    var limitSession = CurrentLimitSession()
    var currentLimits: CurrentLimitSnapshot? { limitSession.snapshot }
    @ObservationIgnored private var timezoneMonitor: Task<Void, Never>?
    @ObservationIgnored private var loginMonitor: Task<Void, Never>?
    @ObservationIgnored private var loginStamp: LoginStamp?
    var error: String?
    var refreshID = 0
    var usageRefreshID = 0
    var automaticSyncIssue: String?

    var progressText: String {
        guard let progress else { return String(localized: "Preparing to sync…") }
        switch progress.stage {
        case .scanning:
            if let scan = progress.scan { return String(localized: "Scanning files: \(scan.completedFiles)/\(scan.totalFiles)") }
            return String(localized: "Finding local logs…")
        case .prices: return String(localized: "Updating model prices…")
        case .repricing: return String(localized: "Calculating cost components…")
        case .api: return String(localized: "Loading server usage…")
        case .statistics: return String(localized: "Updating statistics cache…")
        }
    }

    func start() async {
        guard ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1" else { return }
        guard !started else { return }
        started = true
        error = nil
        do {
            let database = ProcessInfo.processInfo.environment["TOKENTICK_DATABASE"].map { URL(fileURLWithPath: $0) } ?? UsageStore.defaultDatabaseURL
            store = try await Task.detached(priority: .utility) { try UsageStore(databaseURL: database) }.value
            await refresh()
            checkLoginEnvironment()
            monitorLoginEnvironment()
            timezoneMonitor = Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(named: NSNotification.Name.NSSystemTimeZoneDidChange) {
                    guard let self else { return }
                    await self.refresh()
                }
            }
            configureAutomaticSync()
        } catch { self.error = error.localizedDescription; started = false }
    }

    private func configureAutomaticSync() {
        automatic?.stop(); automatic = nil; automaticSyncIssue = nil
        guard store != nil, ProcessInfo.processInfo.environment["TOKENTICK_AUTOSYNC"] != "0" else { return }
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
                lastSync = try await UsageSynchronizer(store: store).synchronize(scope: scope, codexHome: home, onProgress: { [weak self] progress in
                    Task { @MainActor in self?.progress = progress }
                }, onCurrentLimits: { [weak self] snapshot in
                    await MainActor.run {
                        guard let self else { return }
                        self.checkLoginEnvironment()
                        self.limitSession.acceptAPI(snapshot, generation: limitGeneration,
                                                    now: Date().timeIntervalSince1970)
                    }
                })
                checkLoginEnvironment()
                if limitSession.acceptLog(lastSync?.scan?.currentLimits, generation: limitGeneration,
                                          now: Date().timeIntervalSince1970),
                   let log = lastSync?.scan?.currentLimits {
                    let main = currentLimits?.windows.filter { $0.limitID == "codex" } ?? []
                    if !main.isEmpty, main.allSatisfy({ window in log.windows.contains { $0.id == window.id } }) {
                        automatic?.acceptedLog(observedAt: log.observedAt)
                    }
                }
            } catch is CancellationError { error = String(localized: "Sync canceled. Committed data has been kept.") }
            catch {
                self.error = error.localizedDescription
            }
            await refresh()
        }
    }

    func refreshExpiredLimits() async {
        checkLoginEnvironment()
        guard let snapshot = currentLimits,
              Date().timeIntervalSince1970 - snapshot.observedAt > 900 else { return }
        // 已在进行的同步可能更新额度；等它完成后再判断，避免丢失激活请求或重复调用。
        while isSyncing {
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
        }
        guard !Task.isCancelled else { return }
        checkLoginEnvironment()
        guard let snapshot = currentLimits,
              Date().timeIntervalSince1970 - snapshot.observedAt > 900 else { return }
        synchronize(.api)
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
                if self.checkLoginEnvironment(),
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
                let zone = TimeZone.autoupdatingCurrent
                if try store.statisticsTimezone() != zone.identifier {
                    try store.setStatisticsTimezone(zone.identifier)
                }
                // 用量查询会按需修复统计缓存，状态页仍需在修复后读取就绪状态。
                let date = Date().formatted(Date.ISO8601FormatStyle(timeZone: zone).year().month().day().dateSeparator(.dash))
                _ = try store.usageReport(UsageQuery(grouping: .total, fromDate: date, throughDate: date))
                let status = try store.status()
                return (status, try store.lastSynchronizationReport())
            }.value
            if status?.factsRevision != result.0.factsRevision || status?.timezone != result.0.timezone { usageRefreshID += 1 }
            status = result.0
            lastSync = result.1
            refreshID += 1
        } catch { self.error = error.localizedDescription }
    }

}
