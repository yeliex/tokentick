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
    private var watcherFailed = false

    init(app: ApplicationModel) { self.app = app }

    func start() {
        stop()
        self.home = LocalUsageScanner.defaultCodexHome
        schedule = AutomaticSyncSchedule()
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
        arm()
    }

    func stop() {
        timer?.cancel(); timer = nil; watcher = nil; home = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers = []
    }

    func started(_ scope: SynchronizationScope) { schedule.started(scope); arm() }
    func finished() { refreshHome(); if watcher == nil { watch() }; arm() }
    func acceptedLog(observedAt: Double) {
        schedule.acceptedLog(observedAt: Date(timeIntervalSince1970: observedAt))
        arm()
    }
    func cancelled() { schedule.cancelled(); arm() }

    private func watch() {
        watcher = nil
        guard let home else { return }
        do {
            watcher = try CodexLogWatcher(codexHome: home) { [weak self] in
                Task { @MainActor in self?.changed() }
            }
            watcherFailed = false
            app?.automaticSyncIssue = nil
            schedule.watcherAvailable(true)
        } catch {
            if !watcherFailed { AppTelemetry.capture(error, operation: "sync.watcher", warning: true) }
            watcherFailed = true
            app?.automaticSyncIssue = error.localizedDescription
            schedule.watcherAvailable(false)
        }
    }

    private func refreshHome() {
        let current = LocalUsageScanner.defaultCodexHome
        guard current != home else { return }
        home = current
        watch()
        schedule = AutomaticSyncSchedule()
        schedule.watcherAvailable(watcher != nil)
    }

    private func changed() {
        guard home != nil else { return }
        schedule.logsChanged()
        arm()
    }

    private func suspend() { suspended = true; timer?.cancel(); timer = nil }
    private func recover() {
        guard home != nil else { return }
        suspended = false
        refreshHome()
        watch()
        schedule.recovered()
        arm()
    }

    private func arm() {
        timer?.cancel(); timer = nil
        guard home != nil, !suspended, let app, !app.isSyncing else { return }
        // Check process environment and watcher state only; do not scan directories at this frequency.
        let delay = min(30, max(0.01, schedule.nextCheck.timeIntervalSinceNow))
        timer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, let app = self.app, !app.isSyncing, !self.suspended else { return }
            self.refreshHome()
            if self.watcher == nil { self.watch() }
            if let scope = self.schedule.takeDueScope() { app.synchronize(scope) }
            else { self.arm() }
        }
    }
}
