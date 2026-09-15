import SwiftUI
import TokenTickCore

struct DataStatusView: View {
    @Environment(ApplicationModel.self) private var app
    var body: some View {
        Group {
            Section("同步") {
                if app.isSyncing {
                    LabeledContent("正在同步", value: app.progressText)
                } else {
                    LabeledContent("上次同步", value: UsageFormatting.timestamp(app.lastSync?.finishedAt))
                }
                if let issue = app.automaticSyncIssue {
                    Text(issue).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let error = app.error {
                    Text(error).foregroundStyle(.secondary).textSelection(.enabled)
                }
                LabeledContent("请求数", value: app.status?.tables["usage"].map { $0.formatted() } ?? "—")
                LabeledContent("对话数", value: app.status?.tables["threads"].map { $0.formatted() } ?? "—")
                Button(app.isSyncing ? "取消同步" : "刷新") {
                    if app.isSyncing { app.cancelSync() }
                    else { app.synchronize() }
                }.disabled(app.isSyncing && app.progress?.stage == .statistics)
                if let scan = app.lastSync?.scan, scan.issueCount > 0 {
                    ForEach(Array(scan.issues.enumerated()), id: \.offset) { _, issue in
                        Text("\(issue.fileName)：\(issue.message)").font(.caption).textSelection(.enabled)
                    }
                }
            }
            Section("模型价格") {
                LabeledContent("最近同步日期", value: app.status?.priceLastSuccessDate ?? "尚未同步")
                Button("同步价格并重算历史金额") { app.synchronize(.prices) }.disabled(app.isSyncing)
            }
            Section("服务端统计") {
                if let report = app.status?.apiLastReport {
                    LabeledContent("最近请求", value: UsageFormatting.timestamp(report.observedAt))
                    LabeledContent("订阅账号", value: report.accountEmail ?? "未获取").textSelection(.enabled)
                    if let issue = report.issue {
                        Label(issue, systemImage: "exclamationmark.triangle").font(.callout).textSelection(.enabled)
                    }
                }
                Button("刷新") { app.synchronize(.api) }.disabled(app.isSyncing)
            }
            if let sync = app.lastSync, !sync.issues.isEmpty {
                Section("最近同步的问题") {
                    ForEach(Array(sync.issues.enumerated()), id: \.offset) { _, message in Text(message).textSelection(.enabled) }
                }
            }
        }
    }
}
