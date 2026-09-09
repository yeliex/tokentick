import TokenTickCore
import SwiftUI
import AppKit

struct SettingsView: View {
    @Environment(ApplicationModel.self) private var app
    @State private var directory = ""
    var body: some View {
        Form {
            Section("TokenTick") {
                LabeledContent("版本", value: ApplicationInfo.version)
                LabeledContent("系统要求", value: "macOS \(ApplicationInfo.minimumMacOSVersion) 或更新版本")
                LabeledContent("金额单位", value: "美元（USD）")
            }
            Section("统计") {
                Picker("时区", selection: Binding(get: { app.status?.timezone ?? TimeZone.current.identifier },
                                                set: { value in Task { await app.changeTimezone(value) } })) {
                    ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { Text($0).tag($0) }
                }
                Text("日期按所选时区统计，模型价格始终使用 UTC 日期。外观跟随系统。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("数据来源") {
                TextField("Codex 目录", text: $directory)
                Button("保存目录") { app.codexDirectory = (directory as NSString).expandingTildeInPath }
                Toggle("应用运行时自动同步", isOn: Binding(get: { app.automaticSyncEnabled }, set: { app.automaticSyncEnabled = $0 }))
                Text("文件变化合并后采集；每分钟核对本地日志，每五分钟刷新额度和日用量。价格每日成功获取一次。休眠恢复后补扫，退出后停止。")
                    .font(.caption).foregroundStyle(.secondary)
                if let issue = app.automaticSyncIssue { Text(issue).font(.caption).foregroundStyle(.secondary) }
            }
            Section("存储") {
                if let url = app.store?.databaseURL {
                    Text(url.path).font(.caption).textSelection(.enabled)
                    Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                Button("重建统计缓存") { Task { await app.rebuild() } }.disabled(app.isSyncing)
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 540)
        .task { directory = app.codexDirectory }
    }
}
