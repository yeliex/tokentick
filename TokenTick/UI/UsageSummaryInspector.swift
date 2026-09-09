import SwiftUI
import TokenTickCore

struct UsageSummaryInspector: View {
    let row: UsageDisplayRow
    let query: UsageQuery
    let scope: UsageRecordScope
    @State private var showingRecords = false
    var body: some View {
        Form {
            Section {
                Button("查看用量明细") { showingRecords = true }
            }
            Section("归属") {
                Text(row.title).font(.headline).textSelection(.enabled)
                if let thread = row.thread {
                    LabeledContent("任务 ID", value: thread.id)
                    LabeledContent("项目", value: thread.projectName ?? "未知")
                    LabeledContent("最后活跃", value: UsageFormatting.timestamp(thread.lastActiveAt))
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
            .sheet(isPresented: $showingRecords) {
                UsageRecordsView(title: row.title, query: query, scope: scope)
            }
    }
}
