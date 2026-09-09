import TokenTickCore
import AppKit
import SwiftUI

@main
struct TokenTickApp: App {
    @NSApplicationDelegateAdaptor(TokenTickAppDelegate.self) private var delegate
    @State private var model = ApplicationModel()

    var body: some Scene {
        WindowGroup(ApplicationInfo.name, id: "main") {
            ContentView().environment(model)
        }
        .defaultSize(width: 1120, height: 760)

        Settings {
            SettingsView().environment(model)
        }

        MenuBarExtra {
            MenuBarView().environment(model)
        } label: {
            Image("MenuBarIcon")
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class TokenTickAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        // 外观验收只覆盖当前进程，不改写用户或系统偏好。
        switch ProcessInfo.processInfo.environment["TOKENTICK_APPEARANCE"] {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        #endif
        // 同时提供菜单栏入口时，仍以普通 Dock 应用呈现主窗口。
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
