import SwiftUI
import TokenTickCore

struct DataStatusView: View {
    @Environment(ApplicationModel.self) private var app
    let days: [APIDailyBucket]
    let models: [UsageSummary]
    var body: some View {
        Form {
            Section("本地日志") {
                LabeledContent("最近文件扫描", value: UsageFormatting.timestamp(app.status?.lastFileScanAt))
                LabeledContent("已保存记录", value: app.status?.tables["usage"].map { $0.formatted() } ?? "—")
                LabeledContent("日志文件", value: app.status?.tables["scan_files"].map { $0.formatted() } ?? "—")
                Button("重新扫描日志") { app.synchronize(.local) }.disabled(app.isSyncing)
                if let scan = app.lastSync?.scan, scan.issueCount > 0 {
                    ForEach(Array(scan.issues.enumerated()), id: \.offset) { _, issue in
                        Text("\(issue.fileName)：\(issue.message)").font(.caption).textSelection(.enabled)
                    }
                }
            }
            Section("模型价格") {
                LabeledContent("最近同步日期", value: app.status?.priceLastSuccessDate ?? "尚未同步")
                Button("同步价格并重算历史金额") { app.synchronize(.prices) }.disabled(app.isSyncing)
                ForEach(models.filter { $0.unpricedRecords > 0 }, id: \.group) { model in
                    LabeledContent(model.group ?? "其他", value: "\(UsageFormatting.tokens(model.unpricedTokens)) tokens 未定价").help(UsageFormatting.exactTokens(model.unpricedTokens))
                }
            }
            Section("服务端统计") {
                Text("服务端每日总量单独保存。账号和日期口径尚未对齐，暂不与本地用量相加。")
                    .font(.callout).foregroundStyle(.secondary)
                if let report = app.status?.apiLastReport {
                    LabeledContent("最近接口尝试", value: UsageFormatting.timestamp(report.observedAt))
                    LabeledContent("本次额度账号", value: report.accountID ?? "未确认")
                    LabeledContent("本次日桶", value: report.dailyBucketCount.map { "\($0) 条" } ?? "未取得")
                    LabeledContent("本次保存周额度观测", value: "\(report.savedWindows) 条 · \(report.skippedWindows) 条缺少边界")
                    if let issue = report.issue {
                        Label(issue, systemImage: "exclamationmark.triangle").font(.callout).textSelection(.enabled)
                    }
                }
                Button("刷新服务端统计") { app.synchronize(.api) }.disabled(app.isSyncing)
                LabeledContent("最近日桶采集", value: UsageFormatting.timestamp(days.first?.fetchedAt))
                Text("以下显示最近 \(days.count) 条日桶观测。")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                    LabeledContent {
                        TokenText(value: day.tokens)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(day.date)
                            Text(day.accountID.map { "账号 \($0.prefix(8))…" } ?? "未知账号").font(.caption).foregroundStyle(.secondary).help(day.accountID ?? "未知账号")
                        }
                    }
                }
            }
            Section("统计缓存") {
                LabeledContent("时区", value: app.status?.timezone ?? "—")
                LabeledContent("状态", value: app.status?.cacheCurrent == true ? "与事实版本一致" : "等待重建")
                LabeledContent("缓存行数", value: app.status.map { $0.cacheRows.formatted() } ?? "—")
                Button("重建统计缓存") { Task { await app.rebuild() } }.disabled(app.isSyncing)
            }
            if let sync = app.lastSync, !sync.issues.isEmpty {
                Section("最近同步的问题") {
                    ForEach(Array(sync.issues.enumerated()), id: \.offset) { _, message in Text(message).textSelection(.enabled) }
                }
            }
        }.formStyle(.grouped)
    }
}
