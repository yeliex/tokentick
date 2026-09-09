import TokenTickCore
import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(ApplicationModel.self) private var app

    var body: some View {
        Text(ApplicationInfo.name)
        if let today = app.today {
            Text("今日 \(today.totalTokens.formatted(.number.notation(.compactName))) tokens")
            Text("已知金额 \(UsageFormatting.money(today.knownAmountNanoUSD))")
        } else { Text("今日暂无用量数据") }
        if app.isSyncing { Text(app.progressText) }
        if let account = app.status?.apiLastReport?.accountID,
           let limit = app.limits.first(where: { $0.accountID == account && $0.limitID == "codex" && $0.resetsAt > Int64(Date().timeIntervalSince1970) }) {
            Text("最近观测已用 \(limit.lastUsedPercent.formatted())%")
        } else { Text("暂无额度数据") }
        Button("同步用量") { app.synchronize() }.disabled(app.isSyncing)
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
