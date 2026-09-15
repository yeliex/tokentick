import TokenTickCore
import AppKit
import SwiftUI

@main
struct TokenTickApp: App {
    @NSApplicationDelegateAdaptor(TokenTickAppDelegate.self) private var delegate
    @State private var model = ApplicationModel()
    @AppStorage("limitsShowRemaining") private var showRemaining = true

    var body: some Scene {
        Window(ApplicationInfo.name, id: "main") {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--preview-limits") {
                CurrentLimitsView().previewGallery.environment(model)
            } else {
                ContentView().environment(model)
            }
            #else
            ContentView().environment(model)
            #endif
        }
        .defaultSize(width: 1120, height: 760)
        .commands {
            CommandGroup(replacing: .appSettings) { MainWindowSettingsButton() }
            CommandGroup(replacing: .saveItem) {
                Button("关闭窗口") { NSApp.keyWindow?.performClose(nil) }
                    .keyboardShortcut("w")
            }

        }

        Settings {
            SettingsView().environment(model)
        }

        MenuBarExtra {
            MenuBarView().environment(model)
        } label: {
            Image(nsImage: menuBarIcon)
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarIcon: NSImage {
        let windows = model.currentLimits?.windows.filter { $0.limitID == "codex" } ?? []
        let window = windows.first { $0.durationMinutes == 10_080 } ?? windows.first
        guard let window, window.usedPercent.isFinite,
              window.resetsAt.map({ Double($0) > Date().timeIntervalSince1970 }) ?? true else {
            return NSImage(named: "MenuBarIcon") ?? NSImage()
        }
        let percent = showRemaining ? 100 - window.usedPercent : window.usedPercent
        return Self.quotaImages[Int(min(100, max(0, percent)).rounded())]
    }

    // 标签直接使用稳定的图片实例，避免菜单栏宿主反复失效和重新布局。
    private static let quotaImages: [NSImage] = (0...100).map { value in
        let number = String(value)
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { bounds in
            NSImage(named: "MenuBarIcon")?.draw(in: bounds)
            let text = NSAttributedString(string: number, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: number.count == 3 ? 5.5 : 7, weight: .bold),
                .kern: -0.45,
                .foregroundColor: NSColor.black
            ])
            let size = text.size()
            text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
            return true
        }
        image.isTemplate = true
        return image
    }

}

struct MainWindowSettingsButton: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("设置…") {
            NSApp.setActivationPolicy(.regular)
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
            Task { @MainActor in
                await Task.yield()
                openSettings()
            }
        }.keyboardShortcut(",")
    }
}

@MainActor
final class TokenTickAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose(_:)),
                                               name: NSWindow.willCloseNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidBecomeMain(_:)),
                                               name: NSWindow.didBecomeMainNotification, object: nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        // 外观验收只覆盖当前进程，不改写用户或系统偏好。
        switch ProcessInfo.processInfo.environment["TOKENTICK_APPEARANCE"] {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        #endif
        // 启动时显示主窗口；关闭最后一个普通窗口后转为菜单栏应用。
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow,
              closing.canBecomeMain, closing.styleMask.contains(.titled) else { return }
        let hasOtherWindow = NSApp.windows.contains {
            $0 !== closing && ($0.isVisible || $0.isMiniaturized)
                && $0.canBecomeMain && $0.styleMask.contains(.titled)
        }
        if !hasOtherWindow { NSApp.setActivationPolicy(.accessory) }
    }

    @objc private func windowDidBecomeMain(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window.styleMask.contains(.titled) else { return }
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
    }

}
