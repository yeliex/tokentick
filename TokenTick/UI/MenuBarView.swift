import TokenTickCore
import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(ApplicationModel.self) private var app

    private var activeLimits: [CurrentLimitWindow] {
        let now = Int64(Date().timeIntervalSince1970)
        return app.currentLimits?.windows.filter { $0.resetsAt.map { $0 > now } ?? true } ?? []
    }

    var body: some View {
        Text(ApplicationInfo.name)
        if let today = app.today {
            Text("今日 \(UsageFormatting.tokens(today.totalTokens)) tokens").help(UsageFormatting.exactTokens(today.totalTokens))
            Text("已知金额 \(UsageFormatting.money(today.knownAmountNanoUSD))")
        } else { Text("今日暂无用量数据") }
        if app.isSyncing {
            Text(app.progressText)
        } else if app.error != nil {
            Text("最近操作未完成，详见主窗口")
        } else if let sync = app.lastSync, let finishedAt = sync.finishedAt {
            Text("最近同步 \(UsageFormatting.timestamp(finishedAt)) · \(sync.issues.isEmpty ? "完成" : "有问题")")
        } else {
            Text("尚未同步")
        }
        if activeLimits.isEmpty { Text("暂无额度数据") }
        ForEach(activeLimits) { limit in
            Text("\(limit.limitID) · \(limit.durationMinutes.map { "\($0) 分钟" } ?? limit.kind)最近观测已用 \(limit.usedPercent.formatted())%")
            Text("重置于 \(UsageFormatting.timestamp(limit.resetsAt.map(Double.init)))")
        }
        Button("同步用量") { app.synchronize() }.disabled(app.isSyncing || app.store == nil)
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
