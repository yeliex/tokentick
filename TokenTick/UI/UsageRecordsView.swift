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
                    Text(String(localized: "Usage details"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(String(localized: "Close"), action: onClose).keyboardShortcut(.cancelAction)
            }.padding(16)
            Divider()
            if let error { Text(error).foregroundStyle(.secondary).textSelection(.enabled).padding(12) }
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    Table(records) {
                        TableColumn(String(localized: "Time")) { row in
                            Text(row.occurredAt.map { UsageFormatting.timestamp($0, timezone: TimeZone(identifier: query.timezone ?? "UTC") ?? .gmt) }
                                 ?? row.usageDate ?? String(localized: "Unknown"))
                        }.width(min: 110, ideal: 150)
                        TableColumn(String(localized: "Model")) { row in Text(row.model ?? String(localized: "Other")).lineLimit(1).help(row.model ?? String(localized: "Other")) }
                            .width(min: 90, ideal: 120)
                        TableColumn("Tokens") { row in TokenText(value: row.totalTokens).monospacedDigit() }
                            .width(min: 80, ideal: 100)
                        TableColumn(String(localized: "Details")) { row in
                            Button(String(localized: "Details")) { selectedRecord = row }.buttonStyle(.borderless)
                        }.width(50)
                        TableColumn(String(localized: "Cost")) { row in Text(UsageFormatting.money(row.knownAmountNanoUSD)).monospacedDigit() }
                            .width(min: 70, ideal: 90)
                    }
                    .tableStyle(.inset(alternatesRowBackgrounds: false)).scrollContentBackground(.hidden)
                    .overlay {
                        if loading {
                            ProgressView(String(localized: "Loading records"))
                        } else if records.isEmpty && error == nil {
                            ContentUnavailableView(String(localized: "No records yet"), systemImage: "doc.text.magnifyingglass")
                        }
                    }
                    Divider()
                    HStack {
                        Text(String(localized: "Page \(page + 1)")).foregroundStyle(.secondary)
                        Spacer()
                        Button(String(localized: "Previous")) { page -= 1 }.disabled(page == 0 || loading)
                        Button(String(localized: "Next")) { page += 1 }.disabled(!hasMore || loading)
                    }.padding(12)
                }.frame(minWidth: 390, maxHeight: .infinity)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minHeight: 500)
        .sheet(item: $selectedRecord) { record in
            VStack(spacing: 0) {
                HStack {
                    Text(String(localized: "Request details")).font(.headline)
                    Spacer()
                    Button(String(localized: "Close")) { selectedRecord = nil }.keyboardShortcut(.cancelAction)
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
            Section(String(localized: "Turn attribution")) {
                UsageDetailField(String(localized: "Task"), value: record.title ?? record.threadID ?? String(localized: "Unknown"))
                UsageDetailField(String(localized: "Task ID"), value: record.threadID ?? String(localized: "Unknown"))
                UsageDetailField(String(localized: "Project"), value: UsageFormatting.project(record.projectName))
                UsageDetailField(String(localized: "Account"), value: record.accountID ?? String(localized: "Unknown"))
                UsageDetailField(String(localized: "Turn ID"), value: record.turnID ?? String(localized: "Unknown"))
                UsageDetailField(String(localized: "Usage time"), value: UsageFormatting.timestamp(record.occurredAt, timezone: timezone))
                UsageDetailField(String(localized: "Response ID"), value: record.responseID ?? String(localized: "Unknown"))
                UsageDetailField(String(localized: "Hour / minute"), value: record.hour.flatMap { h in record.minute.map { String(format: "%02d:%02d", h, $0) } } ?? String(localized: "Unknown"))
                UsageDetailField(String(localized: "Statistics date"), value: record.statisticalDate ?? String(localized: "Unknown"))
                UsageDetailField(String(localized: "Pricing date"), value: record.usageDate ?? String(localized: "Unknown"))
            }
            Section(String(localized: "Model and pricing mode")) {
                UsageDetailField(String(localized: "Model"), value: record.model ?? String(localized: "Other"))
                UsageDetailField("Fast", value: record.isFast.map { $0 ? String(localized: "Yes") : String(localized: "No") } ?? (record.pricingIsFast ? String(localized: "Yes (additional logs)") : String(localized: "No (standard by default)")))
                UsageDetailField(String(localized: "Long-context pricing"), value: record.isLongContext.map { $0 ? String(localized: "Yes") : String(localized: "No") } ?? String(localized: "Unknown"))
            }
            Section("Tokens") {
                UsageDetailField(String(localized: "Total"), value: UsageFormatting.tokens(record.totalTokens)).help(UsageFormatting.exactTokens(record.totalTokens))
                UsageDetailField(String(localized: "Input"), value: UsageFormatting.tokens(record.inputTokens)).help(UsageFormatting.exactTokens(record.inputTokens))
                UsageDetailField(String(localized: "Cache read"), value: UsageFormatting.tokens(record.cacheReadTokens)).help(UsageFormatting.exactTokens(record.cacheReadTokens))
                UsageDetailField(String(localized: "Cache write"), value: UsageFormatting.tokens(record.cacheWriteTokens)).help(UsageFormatting.exactTokens(record.cacheWriteTokens))
                UsageDetailField(String(localized: "Output"), value: UsageFormatting.tokens(record.outputTokens)).help(UsageFormatting.exactTokens(record.outputTokens))
                UsageDetailField(String(localized: "Reasoning"), value: UsageFormatting.tokens(record.reasoningTokens)).help(UsageFormatting.exactTokens(record.reasoningTokens))
            }
            Section(String(localized: "Applied rates · $ / million tokens")) {
                UsageDetailField(String(localized: "Input"), value: record.inputPrice ?? String(localized: "Unknown"))
                UsageDetailField(String(localized: "Cache read"), value: record.cacheReadPrice ?? String(localized: "Unknown"))
                UsageDetailField(String(localized: "Cache write"), value: record.cacheWritePrice ?? String(localized: "Unknown"))
                UsageDetailField(String(localized: "Output"), value: record.outputPrice ?? String(localized: "Unknown"))
            }
            Section(String(localized: "Exact cost")) {
                UsageDetailField(String(localized: "Input"), value: UsageFormatting.exactMoney(record.inputAmountNanoUSD))
                UsageDetailField(String(localized: "Cache read"), value: UsageFormatting.exactMoney(record.cacheReadAmountNanoUSD))
                UsageDetailField(String(localized: "Cache write"), value: UsageFormatting.exactMoney(record.cacheWriteAmountNanoUSD))
                UsageDetailField(String(localized: "Output"), value: UsageFormatting.exactMoney(record.outputAmountNanoUSD))
                UsageDetailField(String(localized: "Known cost"), value: UsageFormatting.exactMoney(record.knownAmountNanoUSD))
                UsageDetailField(String(localized: "Full cost"), value: UsageFormatting.exactMoney(record.amountNanoUSD))
            }
            Section(String(localized: "Source information")) {
                UsageDetailField(String(localized: "Source"), value: record.source == "local" ? String(localized: "Local logs") : "API")
                UsageDetailField("Rollout ID", value: record.rolloutID ?? String(localized: "Unknown"))
                UsageDetailField(String(localized: "File name"), value: record.fileName ?? String(localized: "Unknown"))
                UsageDetailField(String(localized: "Original event index"), value: record.sourceOrdinal.map(String.init) ?? String(localized: "Unknown"))
                UsageDetailField(String(localized: "Decompressed line number"), value: record.sourceLine.map(String.init) ?? String(localized: "Unknown"))
                if let path = record.lastKnownPath {
                    UsageDetailField(String(localized: "Last scan position"), value: path)
                    Button(String(localized: "Show log in Finder")) {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }.disabled(!FileManager.default.fileExists(atPath: path))
                }
                UsageDetailField(String(localized: "Reasoning effort"), value: record.reasoningEffort ?? String(localized: "Unknown"))
                UsageDetailField(String(localized: "Pricing mode"), value: record.pricingIsFast ? String(localized: "Fast") : String(localized: "Standard"))
            }
        }.formStyle(.grouped).scrollContentBackground(.hidden).textSelection(.enabled)
    }
}
