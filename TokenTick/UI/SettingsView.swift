import SwiftUI
import TokenTickCore

struct SettingsView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(ApplicationModel.self) private var app
    var body: some View {
        TabView(selection: Binding(get: { app.settingsSection }, set: { app.settingsSection = $0 })) {
            GeneralSettingsView().tabItem { Label("通用", systemImage: "gearshape") }.tag("通用")
            DataSettingsView().tabItem { Label("数据状态", systemImage: "externaldrive") }.tag("数据状态")
            StorageSettingsView().tabItem { Label("存储", systemImage: "internaldrive") }.tag("存储")
            Form {
                Section("TokenTick") {
                    LabeledContent("版本", value: ApplicationInfo.version)
                    LabeledContent("系统要求", value: "macOS \(ApplicationInfo.minimumMacOSVersion)+ · Apple Silicon")
                    LabeledContent("金额单位", value: "USD · API 等值估算")
                    Text("本地用量统计 · SwiftUI 原生界面").foregroundStyle(.secondary)
                }
                Section("分发与许可证") {
                    Text("App 与 CLI 使用 ad-hoc 签名和 ZIP 分发。")
                    Text("依赖 GRDB.swift（MIT）和 Zstandard（BSD／GPLv2 双许可）；完整许可证随分发包提供。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).tabItem { Label("关于", systemImage: "info.circle") }.tag("关于")
        }.frame(width: 700, height: 700)
            .scrollContentBackground(.hidden)
            .background(scheme == .dark ? Color.black.opacity(0.5) : Color.white.opacity(0.2))
            .containerBackground(.thinMaterial, for: .window)
            .tint(.primary)
            .task { await app.start() }
    }
}

private struct GeneralSettingsView: View {
    @AppStorage("limitsShowRemaining") private var limitsShowRemaining = true
    @Environment(ApplicationModel.self) private var app
    var body: some View {
        Form {
            Section("额度显示") {
                Picker("显示方式", selection: $limitsShowRemaining) {
                    Text("剩余").tag(true)
                    Text("已使用").tag(false)
                }.pickerStyle(.segmented)
            }
            Section("统计") {
                Picker("时区", selection: Binding(get: { app.status?.timezone ?? TimeZone.current.identifier },
                    set: { value in Task { await app.changeTimezone(value) } })) {
                    ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { Text($0).tag($0) }
                }
                Text("日期标签按所选时区展示，模型价格始终使用 UTC 日期。外观跟随系统。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("数据来源") {
                Toggle("应用运行时自动同步", isOn: Binding(get: { app.automaticSyncEnabled }, set: { app.automaticSyncEnabled = $0 }))
                Text("自动采集本地日志、刷新远端额度并更新价格。退出应用后停止采集。")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Codex 目录", value: LocalUsageScanner.defaultCodexHome.path).textSelection(.enabled)
                Text("由当前进程的 CODEX_HOME 决定，未设置时使用 ~/.codex。")
                    .font(.caption).foregroundStyle(.secondary)
                if let issue = app.automaticSyncIssue { Text(issue).font(.caption).foregroundStyle(.secondary) }
            }
        }.formStyle(.grouped)
    }
}

private struct DataSettingsView: View {
    @Environment(ApplicationModel.self) private var app
    @State private var dashboard = DashboardModel()
    var body: some View {
        DataStatusView(days: dashboard.apiDays, models: dashboard.models)
            .overlay(alignment: .topTrailing) { if dashboard.loading { ProgressView().controlSize(.small).padding() } }
            .safeAreaInset(edge: .bottom) {
                if let error = dashboard.error { Text(error).font(.caption).foregroundStyle(.secondary).padding() }
            }
            .task(id: app.refreshID) {
                guard let store = app.store else { return }
                await dashboard.load(store: store, section: .data, query: UsageQuery(grouping: .total))
            }
    }
}
