import SwiftUI
import TokenTickCore

// grouped Form 会合并相邻文本；每个统计字段保留独立的标签和值供读屏导航。
struct UsageDetailField: View {
    let title: String
    let value: String

    init(_ title: String, value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        LabeledContent(title, value: value)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(title)
            .accessibilityValue(value)
    }
}

struct UsageSummaryInspector: View {
    let row: UsageDisplayRow
    let query: UsageQuery
    let scope: UsageRecordScope
    var navigate: (NavigationSection, UsageQuery) -> Void
    @Environment(ApplicationModel.self) private var app
    @State private var models: [UsageSummary] = []
    @State private var modelError: String?
    @State private var showingRecords = false
    private struct Request: Hashable { let query: UsageQuery; let refresh: Int }
    var body: some View {
        Form {
            Section {
                Button("查看用量明细") { showingRecords = true }
                Button("查看每日用量") { navigate(.daily, query) }
                Button("查看贡献任务") { navigate(.threads, query) }
                Button("查看贡献项目") { navigate(.projects, query) }
            }
            Section("归属") {
                Text(row.title).font(.headline).textSelection(.enabled)
                if let thread = row.thread {
                    UsageDetailField("任务 ID", value: thread.id)
                    UsageDetailField("项目", value: thread.projectName ?? "未知")
                    UsageDetailField("最后活跃", value: UsageFormatting.timestamp(thread.lastActiveAt))
                }
            }
            Section("模型构成") {
                if let modelError { Text(modelError).foregroundStyle(.secondary) }
                ForEach(models, id: \.group) { model in
                    Button { navigate(.threads, query.focused(on: .model, value: model.group)) } label: {
                        LabeledContent(model.group ?? "未知模型", value: UsageFormatting.tokens(model.totalTokens)).help(UsageFormatting.exactTokens(model.totalTokens))
                    }.buttonStyle(.plain)
                }
            }
            Section("Token 分项") {
                UsageDetailField("总量", value: UsageFormatting.tokens(row.summary.totalTokens)).help(UsageFormatting.exactTokens(row.summary.totalTokens))
                UsageDetailField("输入（含缓存）", value: UsageFormatting.tokens(row.summary.inputTokens)).help(UsageFormatting.exactTokens(row.summary.inputTokens))
                UsageDetailField("缓存读取", value: UsageFormatting.tokens(row.summary.cachedInputTokens)).help(UsageFormatting.exactTokens(row.summary.cachedInputTokens))
                UsageDetailField("缓存写入", value: UsageFormatting.tokens(row.summary.cacheWriteInputTokens)).help(UsageFormatting.exactTokens(row.summary.cacheWriteInputTokens))
                UsageDetailField("输出（含推理）", value: UsageFormatting.tokens(row.summary.outputTokens)).help(UsageFormatting.exactTokens(row.summary.outputTokens))
                UsageDetailField("推理", value: UsageFormatting.tokens(row.summary.reasoningOutputTokens)).help(UsageFormatting.exactTokens(row.summary.reasoningOutputTokens))
            }
            Section("已知金额 · USD") {
                UsageDetailField("输入", value: UsageFormatting.money(row.summary.inputAmountNanoUSD))
                UsageDetailField("缓存读取", value: UsageFormatting.money(row.summary.cacheReadAmountNanoUSD))
                UsageDetailField("缓存写入", value: UsageFormatting.money(row.summary.cacheWriteAmountNanoUSD))
                UsageDetailField("输出", value: UsageFormatting.money(row.summary.outputAmountNanoUSD))
                UsageDetailField("已知金额", value: UsageFormatting.money(row.summary.knownAmountNanoUSD))
                Text("缺少价格或计价依据的金额保持未知。缓存包含在输入中，推理包含在输出中。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).textSelection(.enabled)
            .task(id: Request(query: query, refresh: app.refreshID)) {
                guard let store = app.store else { return }
                var request = query
                request.grouping = .model; request.offset = 0; request.limit = 10_000; request.sort = .tokens
                let current = request
                do {
                    let report = try await Task.detached(priority: .userInitiated) { try store.usageReport(current) }.value
                    guard !Task.isCancelled else { return }
                    models = report.rows; modelError = nil
                } catch {
                    guard !Task.isCancelled else { return }
                    models = []; modelError = error.localizedDescription
                }
            }
            .sheet(isPresented: $showingRecords) {
                UsageRecordsView(title: row.title, query: query, scope: scope)
            }
    }
}
