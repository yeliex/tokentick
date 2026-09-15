import AppKit
import SwiftUI
import TokenTickCore

struct UsageRecordsView: View {
    @Environment(ApplicationModel.self) private var app
    let title: String
    let query: UsageQuery
    let scope: UsageRecordScope
    var onClose: () -> Void
    @State private var records: [UsageRecord] = []
    @State private var selectedRecord: UsageRecord?
    @State private var page = 0
    @State private var hasMore = false
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline).lineLimit(1)
                    Text("用量明细")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭", action: onClose).keyboardShortcut(.cancelAction)
            }.padding(16)
            Divider()
            if let error { Text(error).foregroundStyle(.secondary).textSelection(.enabled).padding(12) }
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    Table(records) {
                        TableColumn("时间") { row in
                            Text(row.occurredAt.map { UsageFormatting.timestamp($0, timezone: TimeZone(identifier: query.timezone ?? "UTC") ?? .gmt) }
                                 ?? row.usageDate ?? "未知")
                        }.width(min: 110, ideal: 150)
                        TableColumn("模型") { row in Text(row.model ?? "其他").lineLimit(1).help(row.model ?? "其他") }
                            .width(min: 90, ideal: 120)
                        TableColumn("Tokens") { row in TokenText(value: row.totalTokens).monospacedDigit() }
                            .width(min: 80, ideal: 100)
                        TableColumn("详情") { row in
                            Button("详情") { selectedRecord = row }.buttonStyle(.borderless)
                        }.width(50)
                        TableColumn("费用") { row in Text(UsageFormatting.money(row.knownAmountNanoUSD)).monospacedDigit() }
                            .width(min: 70, ideal: 90)
                    }
                    .tableStyle(.inset(alternatesRowBackgrounds: false)).scrollContentBackground(.hidden)
                    .overlay {
                        if loading {
                            ProgressView("正在查询明细")
                        } else if records.isEmpty && error == nil {
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
                }.frame(minWidth: 390, maxHeight: .infinity)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minHeight: 500)
        .sheet(item: $selectedRecord) { record in
            VStack(spacing: 0) {
                HStack {
                    Text("请求详情").font(.headline)
                    Spacer()
                    Button("关闭") { selectedRecord = nil }.keyboardShortcut(.cancelAction)
                }.padding(20)
                Divider()
                UsageRecordDetail(record: record, timezone: TimeZone(identifier: query.timezone ?? "UTC") ?? .gmt)
            }.frame(width: 600, height: 580)
        }
        .task(id: "\(page)/\(app.usageRefreshID)") {
            guard let store = app.store else { return }
            loading = records.isEmpty; error = nil
            var request = query
            request.limit = 100; request.offset = page * 100
            let current = request
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    return try store.usageRecords(current, scope: scope)
                }
                let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard !Task.isCancelled else { return }
                if records != result.rows { records = result.rows }; hasMore = result.hasMore
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription; records = []; hasMore = false
            }
            loading = false
        }
        .onChange(of: page) { loading = true; records = [] }
    }
}

private struct UsageRecordDetail: View {
    let record: UsageRecord
    let timezone: TimeZone
    var body: some View {
        Form {
            Section("轮次归属") {
                UsageDetailField("任务", value: record.title ?? record.threadID ?? "未知")
                UsageDetailField("任务 ID", value: record.threadID ?? "未知")
                UsageDetailField("项目", value: UsageFormatting.project(record.projectName))
                UsageDetailField("账号", value: record.accountID ?? "未知")
                UsageDetailField("轮次 ID", value: record.turnID ?? "未知")
                UsageDetailField("用量时间", value: UsageFormatting.timestamp(record.occurredAt, timezone: timezone))
                UsageDetailField("响应 ID", value: record.responseID ?? "未知")
                UsageDetailField("小时／分钟", value: record.hour.flatMap { h in record.minute.map { String(format: "%02d:%02d", h, $0) } } ?? "未知")
                UsageDetailField("统计日期", value: record.statisticalDate ?? "未知")
                UsageDetailField("计价日期", value: record.usageDate ?? "未知")
            }
            Section("模型与计价模式") {
                UsageDetailField("模型", value: record.model ?? "其他")
                UsageDetailField("Fast", value: record.isFast.map { $0 ? "是" : "否" } ?? (record.pricingIsFast ? "是（额外日志）" : "否（默认普通）"))
                UsageDetailField("长上下文计价", value: record.isLongContext.map { $0 ? "是" : "否" } ?? "未知")
            }
            Section("Tokens") {
                UsageDetailField("总量", value: UsageFormatting.tokens(record.totalTokens)).help(UsageFormatting.exactTokens(record.totalTokens))
                UsageDetailField("输入", value: UsageFormatting.tokens(record.inputTokens)).help(UsageFormatting.exactTokens(record.inputTokens))
                UsageDetailField("缓存读取", value: UsageFormatting.tokens(record.cacheReadTokens)).help(UsageFormatting.exactTokens(record.cacheReadTokens))
                UsageDetailField("缓存写入", value: UsageFormatting.tokens(record.cacheWriteTokens)).help(UsageFormatting.exactTokens(record.cacheWriteTokens))
                UsageDetailField("输出", value: UsageFormatting.tokens(record.outputTokens)).help(UsageFormatting.exactTokens(record.outputTokens))
                UsageDetailField("思考", value: UsageFormatting.tokens(record.reasoningTokens)).help(UsageFormatting.exactTokens(record.reasoningTokens))
            }
            Section("实际费率 · $ / 百万 tokens") {
                UsageDetailField("输入", value: record.inputPrice ?? "未知")
                UsageDetailField("缓存读取", value: record.cacheReadPrice ?? "未知")
                UsageDetailField("缓存写入", value: record.cacheWritePrice ?? "未知")
                UsageDetailField("输出", value: record.outputPrice ?? "未知")
            }
            Section("精确金额") {
                UsageDetailField("输入", value: UsageFormatting.exactMoney(record.inputAmountNanoUSD))
                UsageDetailField("缓存读取", value: UsageFormatting.exactMoney(record.cacheReadAmountNanoUSD))
                UsageDetailField("缓存写入", value: UsageFormatting.exactMoney(record.cacheWriteAmountNanoUSD))
                UsageDetailField("输出", value: UsageFormatting.exactMoney(record.outputAmountNanoUSD))
                UsageDetailField("已知金额", value: UsageFormatting.exactMoney(record.knownAmountNanoUSD))
                UsageDetailField("完整金额", value: UsageFormatting.exactMoney(record.amountNanoUSD))
            }
            Section("来源信息") {
                UsageDetailField("来源", value: record.source == "local" ? "本地日志" : "API")
                UsageDetailField("Rollout ID", value: record.rolloutID ?? "未知")
                UsageDetailField("文件名", value: record.fileName ?? "未知")
                UsageDetailField("原始事件序号", value: record.sourceOrdinal.map(String.init) ?? "未知")
                UsageDetailField("解压后行号", value: record.sourceLine.map(String.init) ?? "未知")
                if let path = record.lastKnownPath {
                    UsageDetailField("最近扫描位置", value: path)
                    Button("在 Finder 中显示日志") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }.disabled(!FileManager.default.fileExists(atPath: path))
                }
                UsageDetailField("推理深度", value: record.reasoningEffort ?? "未知")
                UsageDetailField("计价模式", value: record.pricingIsFast ? "快速" : "普通")
            }
        }.formStyle(.grouped).scrollContentBackground(.hidden).textSelection(.enabled)
    }
}
