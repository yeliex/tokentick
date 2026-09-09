import SwiftUI
import TokenTickCore

struct UsageSummaryInspector: View {
    let row: UsageDisplayRow
    let query: UsageQuery
    let scope: UsageRecordScope
    var navigate: (NavigationSection, UsageQuery) -> Void
    @Environment(ApplicationModel.self) private var app
    @State private var models: [UsageSummary] = []
    @State private var modelError: String?
    @State private var showingRecords = false
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
                    LabeledContent("任务 ID", value: thread.id)
                    LabeledContent("项目", value: thread.projectName ?? "未知")
                    LabeledContent("最后活跃", value: UsageFormatting.timestamp(thread.lastActiveAt))
                }
            }
            Section("模型构成") {
                if let modelError { Text(modelError).foregroundStyle(.secondary) }
                ForEach(models, id: \.group) { model in
                    Button { navigate(.threads, query.focused(on: .model, value: model.group)) } label: {
                        LabeledContent(model.group ?? "未知模型", value: UsageFormatting.tokens(model.totalTokens))
                    }.buttonStyle(.plain)
                }
            }
            Section("Token 分项") {
                LabeledContent("总量", value: UsageFormatting.tokens(row.summary.totalTokens))
                LabeledContent("输入（含缓存）", value: UsageFormatting.tokens(row.summary.inputTokens))
                LabeledContent("缓存读取", value: UsageFormatting.tokens(row.summary.cachedInputTokens))
                LabeledContent("缓存写入", value: UsageFormatting.tokens(row.summary.cacheWriteInputTokens))
                LabeledContent("输出（含推理）", value: UsageFormatting.tokens(row.summary.outputTokens))
                LabeledContent("推理", value: UsageFormatting.tokens(row.summary.reasoningOutputTokens))
            }
            Section("已知金额 · USD") {
                LabeledContent("输入", value: UsageFormatting.money(row.summary.inputAmountNanoUSD))
                LabeledContent("缓存读取", value: UsageFormatting.money(row.summary.cacheReadAmountNanoUSD))
                LabeledContent("缓存写入", value: UsageFormatting.money(row.summary.cacheWriteAmountNanoUSD))
                LabeledContent("输出", value: UsageFormatting.money(row.summary.outputAmountNanoUSD))
                LabeledContent("已知金额", value: UsageFormatting.money(row.summary.knownAmountNanoUSD))
                Text("缺少价格或计价依据的金额保持未知。缓存包含在输入中，推理包含在输出中。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).textSelection(.enabled)
            .task(id: query) {
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
