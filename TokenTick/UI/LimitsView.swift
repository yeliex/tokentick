import SwiftUI
import Observation
import TokenTickCore

@MainActor @Observable
final class LimitsPageState {
    var period = UsagePeriod.all
    var customFrom = Date()
    var customThrough = Date()
    var account = UsageAccountScope.all
    var accounts: [String] = []
    var page = 0
    var selectedWindow: String?
    var windows: [WeeklyLimitWindow] = []
    var hasMore = false
    var loadedQuery: LimitQuery?
    var error: String?
    var retry = 0
}

struct LimitsView: View {
    @Environment(ApplicationModel.self) private var app
    @Bindable var state: LimitsPageState
    private var timezone: TimeZone { TimeZone(identifier: app.status?.timezone ?? "UTC") ?? .gmt }
    private var criteria: LimitQuery {
        let style = Date.ISO8601FormatStyle(timeZone: timezone).year().month().day().dateSeparator(.dash)
        let dates = state.period == .custom
            ? (state.customFrom.formatted(style), state.customThrough.formatted(style))
            : state.period.dates(timezone: timezone)
        return LimitQuery(timezone: timezone.identifier, fromDate: dates.0, throughDate: dates.1,
                          account: state.account, limitID: "codex")
    }
    private var query: LimitQuery { var value = criteria; value.offset = state.page * 100; return value }
    private struct Request: Hashable { let query: LimitQuery; let refresh: Int; let retry: Int }
    private var request: Request { Request(query: query, refresh: app.refreshID, retry: state.retry) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Spacer()
                UsageDateFilter(period: $state.period, from: $state.customFrom, through: $state.customThrough,
                                periods: [.month, .quarter, .year, .all], timezone: timezone)
                AccountScopeControl(account: $state.account, accounts: state.accounts,
                                    currentAccount: app.currentLimits?.accountID)
            }
            if let error = state.error {
                ContentUnavailableView {
                    Label("无法读取额度记录", systemImage: "exclamationmark.triangle")
                } description: { Text(error) } actions: { Button("重试") { state.retry += 1 } }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if state.loadedQuery != query {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if state.windows.isEmpty {
                ContentUnavailableView {
                    Label("暂无额度记录", systemImage: "calendar")
                } actions: {
                    if state.period != .all || state.account != .all {
                        Button("查看全部记录") { state.period = .all; state.account = .all }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(alignment: .top, spacing: 20) {
                    VStack(spacing: 12) {
                        List(selection: $state.selectedWindow) {
                            ForEach(state.windows) { window in
                                VStack(alignment: .leading, spacing: 9) {
                                    HStack {
                                        Text(shortDate(Double(window.startedAtInferred)))
                                        Text("—").foregroundStyle(.tertiary)
                                        Text(shortDate(Double(window.endsAt)))
                                    }.font(.callout.weight(.medium))
                                    if Set(state.accounts + [app.currentLimits?.accountID].compactMap { $0 }).count > 1 {
                                        Text(window.observedAccountIDs.map { id in
                                            id == app.currentLimits?.accountID ? "当前账号" : "账号 · " + String(id.suffix(8))
                                        }.joined(separator: "、"))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    HStack {
                                        Text(window.endsAt > Date().timeIntervalSince1970 ? "进行中" : "已结束")
                                        if window.resetKind == "early" { Text("· 提前重置") }
                                        Spacer()
                                        Text(window.lastUsedPercent.map { $0.formatted(.number.precision(.fractionLength(0...1))) + "%" } ?? "—")
                                            .monospacedDigit()
                                    }.font(.caption).foregroundStyle(.secondary)
                                    if let percent = window.lastUsedPercent {
                                        ProgressView(value: min(100, max(0, percent)), total: 100).tint(.primary).opacity(0.65)
                                    } else {
                                        Text("使用记录不一致").font(.caption).foregroundStyle(.secondary)
                                    }
                                }.padding(.vertical, 9).tag(window.id)
                            }
                        }.listStyle(.inset).scrollContentBackground(.hidden)
                        if state.page > 0 || state.hasMore {
                            HStack {
                                Button { state.page -= 1 } label: { Image(systemName: "chevron.left") }
                                    .disabled(state.page == 0).help("上一页")
                                Spacer()
                                Text("第 \(state.page + 1) 页").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button { state.page += 1 } label: { Image(systemName: "chevron.right") }
                                    .disabled(!state.hasMore).help("下一页")
                            }.padding(12)
                        }
                    }.frame(minWidth: 230, idealWidth: 270, maxWidth: 310, maxHeight: .infinity)
                        .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 18))
                    ScrollView {
                        if let window = state.windows.first(where: { $0.id == state.selectedWindow }) {
                            WeeklyCycleDetail(window: window, timezone: timezone).padding(.vertical, 8)
                        } else {
                            ContentUnavailableView("选择一个周期", systemImage: "calendar")
                        }
                    }.frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }.padding(.horizontal, 24)
        .padding(.bottom, 24)
        .task(id: request) {
            guard let store = app.store else { return }
            let current = query
            do {
                let result = try await Task.detached(priority: .userInitiated) { try store.weeklyLimitHistory(current) }.value
                guard !Task.isCancelled else { return }
                if state.windows != result.rows { state.windows = result.rows }
                state.hasMore = result.hasMore
                if !state.windows.contains(where: { $0.id == state.selectedWindow }) {
                    state.selectedWindow = state.windows.first?.id
                }
                state.error = nil
            } catch {
                guard !Task.isCancelled else { return }
                state.error = error.localizedDescription
            }
            state.loadedQuery = current
        }
        .task(id: app.refreshID) {
            guard let store = app.store else { return }
            do {
                let options = try await Task.detached { try store.usageFilterOptions() }.value
                guard !Task.isCancelled else { return }
                if state.accounts != options.accounts { state.accounts = options.accounts }
            } catch { state.error = error.localizedDescription }
        }
        .onChange(of: criteria) { state.page = 0; state.selectedWindow = nil }
        .onChange(of: state.page) { state.selectedWindow = nil }
    }

    private func shortDate(_ timestamp: Double) -> String {
        Date(timeIntervalSince1970: timestamp).formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: timezone))
    }
}

private struct WeeklyCycleDetail: View {
    let window: WeeklyLimitWindow
    let timezone: TimeZone
    private func date(_ value: Double) -> String { UsageFormatting.timestamp(value, timezone: timezone) }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text("周期详情").font(.title3.weight(.semibold))
                Text("\(date(Double(window.startedAtInferred))) — \(date(Double(window.endsAt)))")
                    .font(.caption).foregroundStyle(.secondary)
                if window.resetKind == "early" {
                    Text("原定重置时间 \(date(Double(window.scheduledResetAt)))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("已使用").font(.callout).foregroundStyle(.secondary)
                        Text(window.lastUsedPercent.map { $0.formatted(.number.precision(.fractionLength(0...1))) + "%" } ?? "—")
                            .font(.system(size: 32, weight: .semibold)).monospacedDigit()
                    }
                    Spacer()
                    if window.resetKind == "early" {
                        Text("提前重置").font(.caption).padding(8)
                            .background(.primary.opacity(0.05), in: Capsule())
                    }
                }
                if let percent = window.lastUsedPercent {
                    ProgressView(value: min(100, max(0, percent)), total: 100).tint(.primary)
                }
                Divider().padding(.vertical, 4)
                HStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("本地 Tokens").font(.caption).foregroundStyle(.secondary)
                        Text(UsageFormatting.tokens(window.totalTokens)).font(.title3.weight(.semibold))
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("预估费用").font(.caption).foregroundStyle(.secondary)
                        Text(UsageFormatting.money(window.knownAmountNanoUSD ?? window.amountNanoUSD)).font(.title3.weight(.semibold))
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("请求次数").font(.caption).foregroundStyle(.secondary)
                        Text(window.requestCount.map { $0.formatted() } ?? "—").font(.title3.weight(.semibold))
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.monospacedDigit()
            }.usageSurface()
        }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
    }
}
