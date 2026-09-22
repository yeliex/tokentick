import AppKit
import Observation
import TokenTickCore
import TokenTickTelemetry
import UserNotifications

@MainActor @Observable
final class ResetReminderController: NSObject, UNUserNotificationCenterDelegate {
    enum Method: String, CaseIterable {
        case notification, confetti, fireworks, random
        var title: String {
            switch self {
            case .notification: String(localized: "Notification only")
            case .confetti: String(localized: "Confetti")
            case .fireworks: String(localized: "Fireworks")
            case .random: String(localized: "Random")
            }
        }
    }

    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    private(set) var requestingPermission = false
    private(set) var permissionError: String?
    @ObservationIgnored private var detector = LimitResetDetector()
    @ObservationIgnored private let overlay = ResetCelebrationController()
    @ObservationIgnored private var generation = 0

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func invalidate() {
        generation += 1
        detector = LimitResetDetector()
        overlay.dismiss()
    }

    func refreshPermissions() async {
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func requestPermissions() async {
        guard !requestingPermission else { return }
        requestingPermission = true
        defer { requestingPermission = false }
        permissionError = nil
        do {
            let center = UNUserNotificationCenter.current()
            if await center.notificationSettings().authorizationStatus == .notDetermined {
                _ = try await center.requestAuthorization(options: [.alert, .sound])
            }
        } catch {
            permissionError = String(localized: "Could not request notification permission. Try again.")
            AppTelemetry.capture(error, operation: "notifications.authorization", warning: true)
        }
        await refreshPermissions()
    }

    func receive(_ snapshot: CurrentLimitSnapshot) async {
        let events = detector.observe(snapshot, now: Date().timeIntervalSince1970)
        guard !events.isEmpty, UserDefaults.standard.bool(forKey: "resetRemindersEnabled") else { return }
        let body = events.map { event in
            let remaining = max(0, 100 - event.usedPercent).formatted(.number.precision(.fractionLength(0...1)))
            return event.durationMinutes == 10_080
                ? String(localized: "Weekly limit reset · \(remaining)% remaining")
                : String(localized: "5-hour limit reset · \(remaining)% remaining")
        }.joined(separator: "\n")
        await deliver(title: String(localized: "Codex limits reset"), body: body)
    }

    func testReminder() async {
        await requestPermissions()
        guard UserDefaults.standard.bool(forKey: "resetRemindersEnabled") else { return }
        await deliver(title: String(localized: "Reset reminder preview"),
                      body: String(localized: "This is a test. Your Codex limits have not changed."))
    }

    private func deliver(title: String, body: String) async {
        let requestGeneration = generation
        await refreshPermissions()
        guard requestGeneration == generation, UserDefaults.standard.bool(forKey: "resetRemindersEnabled") else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // Let macOS apply notification permissions and Focus delivery rules.
        content.interruptionLevel = .active
        if authorization == .authorized || authorization == .provisional {
            do {
                try await UNUserNotificationCenter.current().add(UNNotificationRequest(
                    identifier: "limit-reset-" + UUID().uuidString, content: content, trigger: nil))
            } catch {
                AppTelemetry.capture(error, operation: "notifications.delivery", warning: true)
            }
        }
        guard requestGeneration == generation, UserDefaults.standard.bool(forKey: "resetRemindersEnabled") else { return }
        playEffect()
    }

    private func playEffect() {
        let defaults = UserDefaults.standard
        let method = Method(rawValue: defaults.string(forKey: "resetReminderMethod") ?? "notification") ?? .notification
        guard method != .notification else { return }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        overlay.play(method == .random ? (Bool.random() ? .confetti : .fireworks) : method)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
