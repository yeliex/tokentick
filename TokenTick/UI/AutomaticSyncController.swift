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

    init(app: ApplicationModel) { self.app = app }

    func start(home: URL) {
        stop()
        self.home = home
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
    func finished() { if watcher == nil { watch() }; arm() }
    func cancelled() { schedule.cancelled(); arm() }

    private func watch() {
        watcher = nil
        guard let home else { return }
        do {
            watcher = try CodexLogWatcher(codexHome: home) { [weak self] in
                Task { @MainActor in self?.changed() }
            }
            app?.automaticSyncIssue = nil
        } catch { app?.automaticSyncIssue = error.localizedDescription }
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
        watch()
        schedule.recovered()
        arm()
    }

    private func arm() {
        timer?.cancel(); timer = nil
        guard home != nil, !suspended, let app, !app.isSyncing else { return }
        let delay = max(0.01, schedule.nextCheck.timeIntervalSinceNow)
        timer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, let app = self.app, !app.isSyncing, !self.suspended else { return }
            if let scope = self.schedule.takeDueScope() { app.synchronize(scope) }
            else { self.arm() }
        }
    }
}
