import TokenTickCore
import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(ApplicationInfo.name)
        Text("暂无用量数据")
        Divider()
        Button("打开 TokenTick") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        SettingsLink { Text("设置…") }
        Divider()
        Button("退出 TokenTick") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
