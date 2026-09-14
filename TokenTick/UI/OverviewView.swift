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
    private struct Request: Hashable { let period: OverviewPeriod; let refresh: Int; let timezone: String; let now: Date }
    private var timezone: String { app.status?.timezone ?? TimeZone.current.identifier }
    private var request: Request { Request(period: period, refresh: app.usageRefreshID, timezone: timezone, now: refreshedAt) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                CurrentLimitsView()
                HStack {
                    Text("用量").font(.title2.weight(.semibold))
                    Spacer()
                    Picker("统计周期", selection: Binding(get: { period }, set: { storedPeriod = $0.rawValue })) {
                        ForEach(OverviewPeriod.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 410)
                }
                if loading && (report == nil || loadedPeriod != period) {
                    ProgressView("正在汇总用量").frame(maxWidth: .infinity, minHeight: 260)
                } else if let error {
                    ContentUnavailableView("无法查询用量", systemImage: "exclamationmark.triangle", description: Text(error))
                    Button("重试") { refreshedAt = Date() }
                } else if let report, let total = report.total {
                    VStack(alignment: .leading, spacing: 22) {
                    HStack(alignment: .top, spacing: 18) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Tokens").font(.callout).foregroundStyle(.secondary)
                            Text(UsageFormatting.tokens(total.totalTokens)).font(.system(size: 34, weight: .semibold)).monospacedDigit()
                                .help(UsageFormatting.exactTokens(total.totalTokens)).textSelection(.enabled)
                            Text("\(total.records.formatted()) 次消耗").font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        VStack(alignment: .leading, spacing: 10) {
                            Text("预估费用").font(.callout).foregroundStyle(.secondary)
                                .help("按模型公开 API 价格估算，不代表订阅账单。")
                            Text(UsageFormatting.money(total.knownAmountNanoUSD)).font(.system(size: 34, weight: .semibold)).monospacedDigit().textSelection(.enabled)
                            Text("USD").font(.caption).foregroundStyle(.secondary)
                                .help(total.unpricedRecords > 0 ? "\(UsageFormatting.tokens(total.unpricedTokens)) Tokens 尚未完整计价，金额仅包含已知部分。" : "金额已完整计价。")
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Divider()
                    HStack(alignment: .top, spacing: 24) {
                        tokenPart("输入", total.inputTokens).help("输入包含缓存读取和缓存写入，不与缓存分项重复累加。")
                        tokenPart("输出", total.outputTokens).help("输出包含思考，不与思考分项重复累加。")
                        tokenPart("思考", total.reasoningOutputTokens)
                        tokenPart("缓存读取", total.cachedInputTokens)
                        tokenPart("缓存写入", total.cacheWriteInputTokens)
                    }
                    }.usageSurface()
                    OverviewChartsView(points: report.trend, hourly: report.hourly, monthly: period == .all, weekly: period == .year,
                                       query: report.query, timezone: timezone)
                    if report.unknownDateTokens > 0 {
                        Label("\(UsageFormatting.tokens(report.unknownDateTokens)) Tokens 无法确定日期，未绘入趋势。", systemImage: "calendar.badge.exclamationmark")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ModelUsageView(models: report.models)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("最近对话").font(.headline)
                            Spacer()
                            Text("金额 / Tokens").font(.caption).foregroundStyle(.secondary)
                        }
                        if report.conversations.isEmpty {
                            Text("暂无可归属到对话的用量").foregroundStyle(.secondary).padding(.vertical)
                        }
                        ForEach(report.conversations) { conversation in
                            Button {
                                var focused = report.query.focused(on: .thread, value: conversation.id)
                                focused.grouping = .thread
                                openConversation(focused)
                            } label: {
                                HStack(spacing: 16) {
                                    Text(conversation.thread.title ?? conversation.id).lineLimit(1).help(conversation.thread.title ?? conversation.id)
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
                    ContentUnavailableView("所选周期暂无用量", systemImage: "chart.bar", description: Text("同步本地日志，或切换其他周期。"))
                }
            }.padding(32).frame(maxWidth: 1280).frame(maxWidth: .infinity)
        }
        .task(id: request) {
            guard let store = app.store else { return }
            let current = request
            loading = report == nil || loadedPeriod != current.period; error = nil
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try store.overviewReport(period: current.period, now: current.now, timezone: current.timezone)
                }.value
                guard !Task.isCancelled else { return }
                if report?.hasSameContent(as: result) != true || loadedPeriod != current.period { report = result }
                loadedPeriod = current.period
            } catch {
                guard !Task.isCancelled else { return }
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
