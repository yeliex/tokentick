import SwiftUI
import TokenTickCore

// Grouped Form merges adjacent text; keep each field's label and value separate for screen readers.
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
    var openRecords: (UsageQuery) -> Void
    @Environment(ApplicationModel.self) private var app
    @State private var models: [UsageSummary] = []
    @State private var modelError: String?
    private struct Request: Hashable { let query: UsageQuery; let refresh: Int }
    var body: some View {
        Form {
            Section {
                Button(String(localized: "Show request records")) { openRecords(query) }
            }
            Section(String(localized: "Attribution")) {
                Text(row.title).font(.headline).textSelection(.enabled)
                if let thread = row.thread {
                    UsageDetailField(String(localized: "Task ID"), value: thread.id)
                    UsageDetailField(String(localized: "Project"), value: UsageFormatting.project(thread.projectName))
                    UsageDetailField(String(localized: "Last active"), value: UsageFormatting.timestamp(thread.lastActiveAt))
                }
            }
            Section(String(localized: "Model breakdown")) {
                if let modelError { Text(modelError).foregroundStyle(.secondary) }
                ForEach(models, id: \.group) { model in
                    LabeledContent(model.group ?? String(localized: "Other"), value: UsageFormatting.tokens(model.totalTokens))
                        .help(UsageFormatting.exactTokens(model.totalTokens))
                }
            }
            Section(String(localized: "Token breakdown")) {
                UsageDetailField(String(localized: "Total"), value: UsageFormatting.tokens(row.summary.totalTokens)).help(UsageFormatting.exactTokens(row.summary.totalTokens))
                UsageDetailField(String(localized: "Input"), value: UsageFormatting.tokens(row.summary.inputTokens)).help(UsageFormatting.exactTokens(row.summary.inputTokens))
                UsageDetailField(String(localized: "Cache read"), value: UsageFormatting.tokens(row.summary.cachedInputTokens)).help(UsageFormatting.exactTokens(row.summary.cachedInputTokens))
                UsageDetailField(String(localized: "Cache write"), value: UsageFormatting.tokens(row.summary.cacheWriteInputTokens)).help(UsageFormatting.exactTokens(row.summary.cacheWriteInputTokens))
                UsageDetailField(String(localized: "Output"), value: UsageFormatting.tokens(row.summary.outputTokens)).help(UsageFormatting.exactTokens(row.summary.outputTokens))
                UsageDetailField(String(localized: "Reasoning"), value: UsageFormatting.tokens(row.summary.reasoningOutputTokens)).help(UsageFormatting.exactTokens(row.summary.reasoningOutputTokens))
            }
            Section(String(localized: "Known cost")) {
                UsageDetailField(String(localized: "Input"), value: UsageFormatting.money(row.summary.inputAmountNanoUSD))
                UsageDetailField(String(localized: "Cache read"), value: UsageFormatting.money(row.summary.cacheReadAmountNanoUSD))
                UsageDetailField(String(localized: "Cache write"), value: UsageFormatting.money(row.summary.cacheWriteAmountNanoUSD))
                UsageDetailField(String(localized: "Output"), value: UsageFormatting.money(row.summary.outputAmountNanoUSD))
                UsageDetailField(String(localized: "Known cost"), value: UsageFormatting.money(row.summary.knownAmountNanoUSD))
            }
        }.formStyle(.grouped).scrollContentBackground(.hidden).textSelection(.enabled)
            .task(id: Request(query: query, refresh: app.usageRefreshID)) {
                guard let store = app.store else { return }
                var request = query
                request.grouping = .model; request.offset = 0; request.limit = 10_000; request.sort = .tokens
                let current = request
                do {
                    let worker = Task.detached(priority: .userInitiated) {
                        try Task.checkCancellation()
                        return try store.usageReport(current)
                    }
                    let report = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                    guard !Task.isCancelled else { return }
                    if models != report.rows { models = report.rows }; modelError = nil
                } catch {
                    guard !Task.isCancelled else { return }
                    models = []; modelError = error.localizedDescription
                }
            }
    }
}
