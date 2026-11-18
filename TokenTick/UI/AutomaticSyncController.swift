import TokenTickTelemetry
import AppKit
import Foundation
import TokenTickCore

@MainActor
final class AutomaticSyncController {
    private weak var app: ApplicationModel?
    private var schedule = AutomaticSyncSchedule()
    private var watcher: CodexLogWatcher?
    private var timer: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var home: URL?
    private var suspended = false
    private var pending = CodexLogChanges(directories: nil)
    private var collecting: CodexLogChanges?

    init(app: ApplicationModel) { self.app = app }

    func start() {
        stop()
        self.home = LocalUsageScanner.defaultCodexHome
        schedule = AutomaticSyncSchedule()
        schedule.applicationActive(NSApp.isActive)
        pending = CodexLogChanges(directories: nil)
        collecting = nil
        suspended = false
        watch()
        let center = NSWorkspace.shared.notificationCenter
        observers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.suspend() }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.recover() }
            }
        ]
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.schedule.applicationActive(NSApp.isActive)
                    self.arm()
                }
            })
        }
        arm()
    }

    func stop() {
        timer?.cancel(); timer = nil; watcher = nil; home = nil
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
    }

    func started(_ scope: SynchronizationScope, directories: [String]?) {
        if scope == .all || scope == .local {
            collecting = CodexLogChanges(directories: directories.map { Set($0) })
            pending = CodexLogChanges()
        }
        schedule.started(scope)
        arm()
    }
    func finished(localScanSucceeded: Bool) {
        if !localScanSucceeded, let collecting { pending.merge(collecting) }
        collecting = nil
        refreshHome()
        arm()
    }
    func acceptedLog(observedAt: Double) {
        schedule.acceptedLog(observedAt: Date(timeIntervalSince1970: observedAt))
        arm()
    }
    func cancelled() { schedule.cancelled(); arm() }
    func sourceDataInvalidated() { changed(CodexLogChanges(directories: nil)) }

    func menuOpened() {
        guard schedule.menuOpened() else { return }
        if !synchronizeIfDue() { arm() }
    }

    private func watch() {
        watcher = nil
        guard let home else { return }
        do {
            watcher = try CodexLogWatcher(codexHome: home) { [weak self] changes in
                Task { @MainActor in
                    guard let self, self.home == home else { return }
                    self.changed(changes)
                }
            }
            app?.automaticSyncIssue = nil
            schedule.watcherAvailable(true)
        } catch {
            AppTelemetry.capture(error, operation: "sync.watcher", warning: true)
            app?.automaticSyncIssue = error.localizedDescription
            schedule.watcherAvailable(false)
        }
    }

    private func refreshHome() {
        let current = LocalUsageScanner.defaultCodexHome
        guard current != home else { return }
        home = current
        schedule = AutomaticSyncSchedule()
        schedule.applicationActive(NSApp.isActive)
        pending = CodexLogChanges(directories: nil)
        watch()
    }

    private func changed(_ changes: CodexLogChanges) {
        guard home != nil else { return }
        pending.merge(changes)
        schedule.logsChanged()
        arm()
    }

    private func suspend() {
        suspended = true; timer?.cancel(); timer = nil
        app?.devices.suspend()
    }
    private func recover() {
        guard home != nil else { return }
        suspended = false
        app?.devices.recovered()
        refreshHome()
        // Keep the existing stream so queued sleep-time changes retain their paths.
        arm()
    }

    private func synchronizeIfDue() -> Bool {
        guard !suspended, let app, !app.isSyncing, !app.isDeletingDeviceData,
              let scope = schedule.takeDueScope() else { return false }
        app.synchronize(scope, localDirectories: pending.directories.map { $0.sorted() })
        return true
    }

    private func arm() {
        timer?.cancel(); timer = nil
        guard home != nil, !suspended, let app, !app.isSyncing, !app.isDeletingDeviceData else { return }
        // Check the configured root only; failed watchers are not retried.
        let delay = min(30, max(0.01, schedule.nextCheck.timeIntervalSinceNow))
        timer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self else { return }
            self.refreshHome()
            if !self.synchronizeIfDue() { self.arm() }
        }
    }
}
