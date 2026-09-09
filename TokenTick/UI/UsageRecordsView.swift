import AppKit
import SwiftUI
import TokenTickCore

struct UsageRecordsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ApplicationModel.self) private var app
    let title: String
    let query: UsageQuery
    let scope: UsageRecordScope
    @State private var records: [UsageRecord] = []
    @State private var selection: Int64?
    @State private var page = 0
    @State private var hasMore = false
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline).lineLimit(1)
                    Text("用量明细 · \(query.timezone ?? app.status?.timezone ?? "UTC")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(16)
            Divider()
            if let error { Text(error).foregroundStyle(.secondary).textSelection(.enabled).padding(12) }
            HSplitView {
                VStack(spacing: 0) {
                    Table(records, selection: $selection) {
                        TableColumn("发生时间") { row in
                            Text(row.occurredAt.map { UsageFormatting.timestamp($0, timezone: TimeZone(identifier: query.timezone ?? "UTC") ?? .gmt) }
                                 ?? row.usageDate ?? "未知")
                        }.width(min: 145, ideal: 170)
                        TableColumn("模型") { row in Text(row.model ?? "未知").lineLimit(1).help(row.model ?? "未知") }
                            .width(min: 100, ideal: 140)
                        TableColumn("Tokens") { row in Text(UsageFormatting.tokens(row.totalTokens)).monospacedDigit() }
                            .width(min: 80, ideal: 100)
                        TableColumn("已知 USD") { row in Text(UsageFormatting.money(row.knownAmountNanoUSD)).monospacedDigit() }
                            .width(min: 70, ideal: 90)
                    }
                    .overlay {
                        if records.isEmpty && !loading && error == nil {
                            ContentUnavailableView("暂无明细", systemImage: "doc.text.magnifyingglass")
                        }
                    }
                    Divider()
                    HStack {
                        Text("第 \(page + 1) 页").foregroundStyle(.secondary)
                        Spacer()
                        Button("上一页") { page -= 1 }.disabled(page == 0 || loading)
                        Button("下一页") { page += 1 }.disabled(!hasMore || loading)
                    }.padding(12)
                }.frame(minWidth: 510)
                if let record = records.first(where: { $0.id == selection }) {
                    UsageRecordDetail(record: record, timezone: TimeZone(identifier: query.timezone ?? "UTC") ?? .gmt)
                        .frame(minWidth: 320, idealWidth: 360)
                } else {
                    ContentUnavailableView("选择一条用量", systemImage: "doc.text.magnifyingglass",
                        description: Text("查看分项计价和日志证据。"))
                        .frame(minWidth: 320, idealWidth: 360)
                }
            }
        }
        .frame(minWidth: 860, idealWidth: 980, minHeight: 540, idealHeight: 680)
        .task(id: "\(page)/\(app.refreshID)") {
            guard let store = app.store else { return }
            loading = true; error = nil; selection = nil
            var request = query
            request.limit = 100; request.offset = page * 100
            let current = request
            do {
                let result = try await Task.detached(priority: .userInitiated) { try store.usageRecords(current, scope: scope) }.value
                guard !Task.isCancelled else { return }
                records = result.rows; hasMore = result.hasMore
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription; records = []; hasMore = false
            }
            loading = false
        }
    }
}

private struct UsageRecordDetail: View {
    let record: UsageRecord
    let timezone: TimeZone
    @State private var evidenceExpanded = false
    var body: some View {
        Form {
            Section("请求归属") {
                LabeledContent("任务", value: record.title ?? record.threadID ?? "未知")
                LabeledContent("任务 ID", value: record.threadID ?? "未知")
                LabeledContent("项目", value: record.projectName ?? "未知")
                LabeledContent("账号", value: record.accountID ?? "未知")
                LabeledContent("轮次 ID", value: record.turnID ?? "未知")
                LabeledContent("请求 ID", value: record.requestID ?? "未知")
                LabeledContent("响应 ID", value: record.responseID ?? "未知")
                LabeledContent("发生时间", value: UsageFormatting.timestamp(record.occurredAt, timezone: timezone))
                LabeledContent("统计日期", value: record.statisticalDate ?? "未知")
                LabeledContent("计价日期 · UTC", value: record.usageDate ?? "未知")
            }
            Section("模型与计价模式") {
                LabeledContent("模型", value: record.model ?? "未知")
                LabeledContent("Fast", value: record.isFast.map { $0 ? "是" : "否" } ?? "未知")
                LabeledContent("长上下文计价", value: record.isLongContext.map { $0 ? "是" : "否" } ?? "未知")
            }
            Section("Tokens") {
                LabeledContent("总量", value: UsageFormatting.tokens(record.totalTokens))
                LabeledContent("输入（含缓存）", value: UsageFormatting.tokens(record.inputTokens))
                LabeledContent("缓存读取", value: UsageFormatting.tokens(record.cacheReadTokens))
                LabeledContent("缓存写入", value: UsageFormatting.tokens(record.cacheWriteTokens))
                LabeledContent("输出（含推理）", value: UsageFormatting.tokens(record.outputTokens))
                LabeledContent("推理", value: UsageFormatting.tokens(record.reasoningTokens))
            }
            Section("实际费率 · USD / 百万 tokens") {
                LabeledContent("输入", value: record.inputPrice ?? "未知")
                LabeledContent("缓存读取", value: record.cacheReadPrice ?? "未知")
                LabeledContent("缓存写入", value: record.cacheWritePrice ?? "未知")
                LabeledContent("输出", value: record.outputPrice ?? "未知")
                Text("费率已包含已确认的 Fast／长上下文规则，不需要再乘倍率。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("精确金额 · USD") {
                LabeledContent("输入", value: UsageFormatting.exactMoney(record.inputAmountNanoUSD))
                LabeledContent("缓存读取", value: UsageFormatting.exactMoney(record.cacheReadAmountNanoUSD))
                LabeledContent("缓存写入", value: UsageFormatting.exactMoney(record.cacheWriteAmountNanoUSD))
                LabeledContent("输出", value: UsageFormatting.exactMoney(record.outputAmountNanoUSD))
                LabeledContent("已知金额", value: UsageFormatting.exactMoney(record.knownAmountNanoUSD))
                LabeledContent("完整金额", value: UsageFormatting.exactMoney(record.amountNanoUSD))
            }
            Section("统计证据") {
                LabeledContent("来源", value: record.source == "local" ? "本地日志" : "API")
                LabeledContent("Rollout ID", value: record.rolloutID ?? "未知")
                LabeledContent("文件名", value: record.fileName ?? "未知")
                LabeledContent("解压后行号", value: record.sourceLine.map(String.init) ?? "未知")
                if let path = record.lastKnownPath {
                    LabeledContent("最近扫描位置", value: path)
                    Button("在 Finder 中显示日志") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }.disabled(!FileManager.default.fileExists(atPath: path))
                    Text("位置在扫描后更新，日志归档或移除不会删除已保存的用量与证据。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup("统计证据 JSON", isExpanded: $evidenceExpanded) {
                    Text(record.evidenceJSON).font(.system(.caption, design: .monospaced))
                }
            }
        }.formStyle(.grouped).textSelection(.enabled)
    }
}
