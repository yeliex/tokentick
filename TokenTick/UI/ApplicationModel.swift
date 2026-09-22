import Foundation
import Observation
import TokenTickCore
import TokenTickTelemetry

@MainActor @Observable
final class ApplicationModel {
    private(set) var store: UsageStore?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var automatic: AutomaticSyncController?
    private var started = false
    let storage = CodexStorageModel()
    let resetReminders = ResetReminderController()
    var requestedPage: AppPage?
    var isRefreshingAPI = false
    @ObservationIgnored private let displayCache = LocalDisplayCache(onDiagnostic: { AppTelemetry.capture($0) })
    var isSyncing = false
    var progress: SynchronizationProgress?
    var status: StoreStatus?
    var lastSync: SynchronizationReport?
    var limitSession = CurrentLimitSession()
    var currentLimits: CurrentLimitSnapshot? { limitSession.snapshot }
    @ObservationIgnored private var timezoneMonitor: Task<Void, Never>?
    @ObservationIgnored private var loginMonitor: Task<Void, Never>?
    @ObservationIgnored private var loginStamp: CodexLoginStamp?
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
        await storage.loadCache()
        checkLoginEnvironment()
        if let stamp = loginStamp {
            let cached = await displayCache.api(for: stamp)
            checkLoginEnvironment()
            if loginStamp == stamp, let cached {
                limitSession.restoreCached(cached, now: Date().timeIntervalSince1970)
            }
        }
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
        } catch {
            AppTelemetry.capture(error, operation: "database.open")
            self.error = error.localizedDescription; started = false
        }
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
        isRefreshingAPI = scope == .all || scope == .api || scope == .remote
        automatic?.started(scope)
        error = nil
        let home = LocalUsageScanner.defaultCodexHome
        syncTask = Task { [self] in
            defer { isRefreshingAPI = false; isSyncing = false; progress = nil; syncTask = nil; automatic?.finished() }
            do {
                lastSync = try await UsageSynchronizer(store: store).synchronize(scope: scope, codexHome: home, onProgress: { [weak self] progress in
                    Task { @MainActor in self?.progress = progress }
                }, onCurrentLimits: { [weak self] snapshot in
                    guard let self else { return }
                    await self.receiveCurrentLimits(snapshot, generation: limitGeneration)
                }, onAPIFailure: { [weak self] in
                    await MainActor.run {
                        self?.checkLoginEnvironment()
                        self?.isRefreshingAPI = false
                    }
                }, onDiagnostic: { diagnostic in
                    AppTelemetry.capture(diagnostic)
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
                AppTelemetry.capture(error, operation: "synchronization")
                self.error = error.localizedDescription
            }
            await refresh()
        }
    }

    func refreshExpiredLimits() async {
        checkLoginEnvironment()
        guard let snapshot = currentLimits,
              Date().timeIntervalSince1970 - snapshot.observedAt > 900 else { return }
        // Wait for an active sync before checking freshness to avoid lost activation requests or duplicate calls.
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

    private func receiveCurrentLimits(_ snapshot: CurrentLimitSnapshot?, generation: Int) async {
        checkLoginEnvironment()
        isRefreshingAPI = false
        guard generation == limitSession.generation else { return }
        let accepted = limitSession.acceptAPI(snapshot, generation: generation, now: Date().timeIntervalSince1970)
        if accepted, let snapshot {
            await resetReminders.receive(snapshot)
        }
        guard generation == limitSession.generation else { return }
        if accepted, let snapshot, let stamp = loginStamp {
            await displayCache.saveAPI(snapshot, login: stamp)
        } else if limitSession.snapshot == nil {
            await displayCache.clearAPI()
        }
    }

    @discardableResult private func checkLoginEnvironment() -> Bool {
        let home = LocalUsageScanner.defaultCodexHome
        let stamp = CodexLoginStamp(home: home)
        guard stamp != loginStamp else { return false }
        loginStamp = stamp
        limitSession.invalidate()
        resetReminders.invalidate()
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
                // Usage queries can repair the cache; reload status after that repair completes.
                let date = Date().formatted(Date.ISO8601FormatStyle(timeZone: zone).year().month().day().dateSeparator(.dash))
                _ = try store.usageReport(UsageQuery(grouping: .total, fromDate: date, throughDate: date))
                let status = try store.status()
                return (status, try store.lastSynchronizationReport())
            }.value
            if status?.factsRevision != result.0.factsRevision || status?.timezone != result.0.timezone { usageRefreshID += 1 }
            status = result.0
            lastSync = result.1
            refreshID += 1
        } catch {
            AppTelemetry.capture(error, operation: "database.refresh")
            self.error = error.localizedDescription
        }
    }

}

extension AppTelemetry {
    static func capture(_ diagnostic: SynchronizationDiagnostic) {
        guard !diagnostic.isCancellation else { return }
        captureIssue(operation: diagnostic.operation, reason: diagnostic.reason, errorType: diagnostic.errorType,
                     code: diagnostic.code, count: diagnostic.count, warning: diagnostic.warning,
                     rpcMethod: diagnostic.rpcMethod, durationMilliseconds: diagnostic.durationMilliseconds,
                     decodingFailure: diagnostic.decodingFailure, errorMessage: diagnostic.errorMessage)
    }
}
