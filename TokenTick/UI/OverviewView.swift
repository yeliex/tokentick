import TokenTickTelemetry
import SwiftUI
import TokenTickCore

struct OverviewView: View {
    @Environment(ApplicationModel.self) private var app
    var openConversation: (UsageQuery) -> Void
    @SceneStorage("overview.period") private var storedPeriod = OverviewPeriod.week.rawValue
    private var period: OverviewPeriod { OverviewPeriod(rawValue: storedPeriod) ?? .week }
    @State private var loadedPeriod: OverviewPeriod?
    @State private var report: OverviewReport?
    @State private var loading = false
    @State private var error: String?
    @State private var refreshedAt = Date()
    private struct Request: Hashable { let period: OverviewPeriod; let refresh: Int; let timezone: String; let now: Date; let device: UsageValueFilter }
    private var timezone: String { app.status?.timezone ?? TimeZone.current.identifier }
    private var request: Request { Request(period: period, refresh: app.usageRefreshID, timezone: timezone, now: refreshedAt, device: app.selectedDevice) }
    private var selectionChanged: Bool { loadedPeriod != period || report?.query.filters.device != app.selectedDevice }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                CurrentLimitsView()
                if !app.devices.coverageGaps.isEmpty {
                    Text(String(localized: "Device history has not been fully collected: \(app.devices.coverageGaps.map { app.devices.name($0) }.joined(separator: ", ")). Sync available sources to complete the history."))
                        .font(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    Text(String(localized: "Usage")).font(.title2.weight(.semibold))
                    Spacer()
                    if !app.devices.configuration.devices.isEmpty || !app.devices.configuration.removedNames.isEmpty {
                        Picker(String(localized: "Device"), selection: Binding(get: { app.selectedDevice }, set: { app.selectedDevice = $0 })) {
                            Text(String(localized: "All devices")).tag(UsageValueFilter.all)
                            Text(String(localized: "Local")).tag(UsageValueFilter.value("local"))
                            ForEach(app.devices.configuration.devices) { device in
                                Text(device.name).tag(UsageValueFilter.value(device.id))
                            }
                            ForEach(app.devices.configuration.removedNames.keys.sorted(), id: \.self) { id in
                                Text(app.devices.name(id)).tag(UsageValueFilter.value(id))
                            }
                        }.labelsHidden().frame(width: 140)
                    }
                    Picker(String(localized: "Period"), selection: Binding(get: { period }, set: { storedPeriod = $0.rawValue })) {
                        ForEach(OverviewPeriod.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().controlSize(.regular)
                        .fixedSize(horizontal: true, vertical: true)
                }
                if selectionChanged && (loading || report != nil) {
                    ProgressView(String(localized: "Summarizing usage")).frame(maxWidth: .infinity, minHeight: 260)
                } else if let error {
                    ContentUnavailableView(String(localized: "Unable to load usage"), systemImage: "exclamationmark.triangle", description: Text(error))
                    Button(String(localized: "Retry")) { refreshedAt = Date() }
                } else if let report, let total = report.total {
                    VStack(alignment: .leading, spacing: 22) {
                    HStack(alignment: .top, spacing: 18) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Tokens").font(.callout).foregroundStyle(.secondary)
                            Text(UsageFormatting.tokens(total.totalTokens)).font(.system(size: 34, weight: .semibold)).monospacedDigit()
                                .help(UsageFormatting.exactTokens(total.totalTokens)).textSelection(.enabled)
                            Text(String(localized: "Requests: \(total.records.formatted())")).font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        VStack(alignment: .leading, spacing: 10) {
                            Text(String(localized: "Estimated cost")).font(.callout).foregroundStyle(.secondary)
                                .help(String(localized: "Estimated using public model API prices, not your subscription bill."))
                            Text(UsageFormatting.money(total.knownAmountNanoUSD)).font(.system(size: 34, weight: .semibold)).monospacedDigit().textSelection(.enabled)
                                .help(total.unpricedRecords > 0 ? String(localized: "\(UsageFormatting.tokens(total.unpricedTokens)) tokens are not fully priced. Cost includes only known amounts.") : String(localized: "All usage is priced."))
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Divider()
                    HStack(alignment: .top, spacing: 24) {
                        tokenPart(String(localized: "Input"), total.inputTokens).help(String(localized: "Input includes cache reads and writes. Cache components are not counted twice."))
                        tokenPart(String(localized: "Output"), total.outputTokens).help(String(localized: "Output includes reasoning. Reasoning is not counted twice."))
                        tokenPart(String(localized: "Reasoning"), total.reasoningOutputTokens)
                        tokenPart(String(localized: "Cache read"), total.cachedInputTokens)
                        tokenPart(String(localized: "Cache write"), total.cacheWriteInputTokens)
                    }
                    }.usageSurface()
                    if period != .day {
                        OverviewChartsView(points: report.trend, hourly: report.hourly, monthly: period == .all, weekly: period == .year,
                                           query: report.query, timezone: timezone)
                        if report.unknownDateTokens > 0 {
                            Label(String(localized: "\(UsageFormatting.tokens(report.unknownDateTokens)) tokens have no known date and are excluded from the trend."), systemImage: "calendar.badge.exclamationmark")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    ModelUsageView(models: report.models, modes: report.modes, efforts: report.efforts)
                    CodexStorageSummaryView()
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(String(localized: "Recent conversations")).font(.headline)
                            Spacer()
                            Text(String(localized: "Cost / Tokens")).font(.caption).foregroundStyle(.secondary)
                        }
                        if report.conversations.isEmpty {
                            Text(String(localized: "No usage attributed to conversations")).foregroundStyle(.secondary).padding(.vertical)
                        }
                        ForEach(report.conversations) { conversation in
                            Button {
                                var focused = report.query.focused(on: .thread, value: conversation.id)
                                focused.grouping = .thread
                                openConversation(focused)
                            } label: {
                                HStack(spacing: 16) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(conversation.thread.title ?? conversation.id).lineLimit(1).help(conversation.thread.title ?? conversation.id)
                                        Text(UsageFormatting.project(conversation.thread.projectName))
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                            .help(UsageFormatting.project(conversation.thread.projectName))
                                    }
                                    Spacer()
                                    Text(UsageFormatting.money(conversation.summary.knownAmountNanoUSD)).frame(width: 105, alignment: .trailing)
                                    TokenText(value: conversation.summary.totalTokens).frame(width: 100, alignment: .trailing)
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                }.monospacedDigit().contentShape(Rectangle()).padding(.vertical, 5)
                            }.buttonStyle(.plain)
                            Divider()
                        }
                    }.usageSurface()
                } else {
                    ContentUnavailableView(String(localized: "No usage in the selected period"), systemImage: "chart.bar")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                if report?.total == nil || error != nil || (selectionChanged && (loading || report != nil)) {
                    CodexStorageSummaryView()
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
                .padding(32).frame(maxWidth: 1280).frame(maxWidth: .infinity)
        }
        .task(id: request) {
            guard let store = app.store else { return }
            let current = request
            loading = report == nil || selectionChanged; error = nil
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try store.overviewReport(period: current.period, now: current.now, timezone: current.timezone, device: current.device)
                }
                let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard !Task.isCancelled else { return }
                if report?.hasSameContent(as: result) != true || loadedPeriod != current.period { report = result }
                loadedPeriod = current.period
            } catch {
                guard !Task.isCancelled else { return }
                AppTelemetry.capture(error, operation: "overview.query")
                self.error = error.localizedDescription; report = nil
            }
            loading = false
        }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                refreshedAt = Date()
            }
        }
        .onChange(of: period) { refreshedAt = Date() }
        .onChange(of: app.usageRefreshID) { refreshedAt = Date() }
    }
    private func tokenPart(_ title: String, _ value: Int64?) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TokenText(value: value).font(.system(size: 18, weight: .medium)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension View {
    func usageSurface() -> some View {
        modifier(LumaSurface())
    }
}
