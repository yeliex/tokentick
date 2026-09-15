import SwiftUI
import TokenTickCore
import Observation

@MainActor @Observable
final class UsageDetailsState {
    var grouping = UsageGrouping.day
    var period = UsagePeriod.month
    var dashboard = DashboardModel()
    var page = 0
    var selectedRow: String?
    var filters = UsageFilters()
    var account: UsageAccountScope = .all
    var sort = UsageSort.automatic
    var customFrom = Date()
    var customThrough = Date()
    var detail: UsageDetailDestination?
    var restoredCriteria: UsageQuery?
    var options: UsageFilterOptions?
    var retry = 0
}

struct UsageRecordDestination { let title: String; let query: UsageQuery }

enum UsageDetailDestination {
    case summary(UsageSummaryDestination)
    case records(UsageRecordDestination)
}

struct UsageSummaryDestination: Identifiable {
    let id = UUID()
    let row: UsageDisplayRow
    let query: UsageQuery
}


struct UsageDetailsView: View {
    @Environment(ApplicationModel.self) private var app
    @Binding var initialQuery: UsageQuery?
    @Bindable var state: UsageDetailsState
    private struct Request: Hashable { let query: UsageQuery; let refresh: Int; let retry: Int }
    private var timezone: TimeZone { TimeZone(identifier: app.status?.timezone ?? "UTC") ?? .gmt }
    private var query: UsageQuery {
        let style = Date.ISO8601FormatStyle(timeZone: timezone).year().month().day().dateSeparator(.dash)
        let dates = state.period == .custom ? (state.customFrom.formatted(style), state.customThrough.formatted(style)) : state.period.dates(timezone: timezone)
        return UsageQuery(grouping: state.grouping,
            timezone: timezone.identifier, fromDate: dates.0, throughDate: dates.1, account: state.account,
            limit: 100, offset: state.page * 100, filters: state.filters, sort: state.sort)
    }
    var body: some View {
        VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            Picker("聚合方式", selection: $state.grouping) {
                                Text("每日").tag(UsageGrouping.day)
                                Text("项目").tag(UsageGrouping.project)
                                Text("任务").tag(UsageGrouping.thread)
                            }.pickerStyle(.segmented).labelsHidden().fixedSize(horizontal: true, vertical: true)
                            UsageDateFilter(period: periodSelection, from: $state.customFrom, through: $state.customThrough,
                                            periods: [.today, .week, .month, .quarter, .year, .all], timezone: timezone)
                        TextField("搜索任务标题或 ID", text: $state.filters.search)
                            .textFieldStyle(.roundedBorder).frame(width: 130)
                        Picker("项目", selection: $state.filters.project) {
                            Text("全部项目").tag(UsageValueFilter.all)
                            ForEach(state.options?.projects ?? [], id: \.self) { Text(UsageFormatting.project($0)).tag(UsageValueFilter.value($0)) }

                        }.labelsHidden().frame(width: 100)
                        Picker("模型", selection: $state.filters.model) {
                            Text("全部模型").tag(UsageValueFilter.all)
                            ForEach(state.options?.models ?? [], id: \.self) { Text($0).tag(UsageValueFilter.value($0)) }

                        }.labelsHidden().frame(width: 110)
                        AccountScopeControl(account: $state.account, accounts: state.options?.accounts ?? [],
                                            currentAccount: app.currentLimits?.accountID)
                        Picker("排序", selection: $state.sort) {
                            ForEach(UsageSort.allCases, id: \.self) { Text($0.title).tag($0) }
                        }.labelsHidden().frame(width: 100)
                        }
                    }.scrollIndicators(.hidden).controlSize(.small).frame(height: 28)
                    HStack(spacing: 20) {
                        summaryMetric("Tokens", UsageFormatting.tokens(currentTotal?.totalTokens))
                        summaryMetric("预估费用", UsageFormatting.money(currentTotal?.knownAmountNanoUSD))
                        summaryMetric("请求次数", currentTotal.map { $0.records.formatted() } ?? "—")
                        Spacer(minLength: 8)
                        Text(rangeLabel).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).help(rangeLabel).textSelection(.enabled)
                    }.padding(14)
                        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                }.padding(.bottom, 14)
                if let error = state.dashboard.error {
                    ContentUnavailableView {
                        Label("查询失败", systemImage: "exclamationmark.triangle")
                    } description: { Text(error) } actions: { Button("重试") { state.retry += 1 } }
                } else if state.dashboard.loadedQuery != query {
                    ProgressView("正在查询用量").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    UsageTableView(rows: state.dashboard.rows, isThread: state.grouping == .thread,
                                   hasMore: state.dashboard.hasMore, totalGroups: state.dashboard.totalGroups, selection: $state.selectedRow, page: $state.page, openRow: openRow, showDetails: { row in
                                       state.detail = .summary(UsageSummaryDestination(row: row,
                                           query: query.focused(on: query.grouping, value: row.summary.group)))
                                   })
                        .overlay {
                            if state.dashboard.rows.isEmpty { ContentUnavailableView("所选范围暂无用量", systemImage: "tablecells") }
                        }
                }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
        .sheet(isPresented: Binding(get: { state.detail != nil }, set: { if !$0 { state.detail = nil } })) {
            VStack(spacing: 0) {
                switch state.detail {
                case .summary(let destination):
                    HStack {
                        Text(destination.row.title).font(.headline).lineLimit(1)
                        Spacer()
                        Button("关闭") { state.detail = nil }.keyboardShortcut(.cancelAction)
                    }.padding(20)
                    Divider()
                    UsageSummaryInspector(row: destination.row, query: destination.query) { focused in
                        state.detail = .records(UsageRecordDestination(title: destination.row.title, query: focused))
                    }
                case .records(let destination):
                    UsageRecordsView(title: destination.title, query: destination.query, scope: .all,
                                     onClose: { state.detail = nil })
                case nil:
                    EmptyView()
                }
            }.frame(width: 800, height: 600)
        }
        .task {
            if let initialQuery {
                state.detail = .records(UsageRecordDestination(title: "请求明细", query: initialQuery))
                self.initialQuery = nil
            }
        }
        .task(id: Request(query: query, refresh: app.usageRefreshID, retry: state.retry)) {
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let store = app.store else { return }
            await state.dashboard.load(store: store, query: query)
        }
        .task(id: Request(query: optionsQuery, refresh: app.usageRefreshID, retry: state.retry)) {
            guard let store = app.store else { return }
            do {
                let scope = optionsQuery
                let options = try await Task.detached { try store.usageFilterOptions(scope) }.value
                guard !Task.isCancelled else { return }
                if state.options != options { state.options = options }
                if case .value(let project) = state.filters.project, !options.projects.contains(project) { state.filters.project = .all }
                if case .value(let model) = state.filters.model, !options.models.contains(model) { state.filters.model = .all }
            } catch { state.dashboard.error = error.localizedDescription }
        }
        .onChange(of: criteria) {
            if state.restoredCriteria == criteria { state.restoredCriteria = nil; return }
            state.page = 0; state.selectedRow = nil
        }

    }
    private func summaryMetric(_ title: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.semibold)).monospacedDigit().textSelection(.enabled)
        }.fixedSize(horizontal: true, vertical: false)
    }
    private func openRow(_ row: UsageDisplayRow) {
        let focused = query.focused(on: query.grouping, value: row.summary.group)
        state.selectedRow = nil
        if state.grouping == .thread || (state.grouping == .day && row.summary.group == nil) {
            state.detail = .records(UsageRecordDestination(title: row.title, query: focused))
        } else {
            var next = focused
            next.grouping = .thread
            restore(next)
        }
    }
    private var optionsQuery: UsageQuery {
        var scope = query
        let from = scope.filters.occurredFrom, before = scope.filters.occurredBefore
        scope.filters = UsageFilters()
        scope.filters.occurredFrom = from; scope.filters.occurredBefore = before
        scope.grouping = .total; scope.offset = 0; scope.sort = .automatic
        return scope
    }
    private var criteria: UsageQuery { var value = query; value.offset = 0; return value }
    private var currentTotal: UsageSummary? { state.dashboard.loadedQuery == query ? state.dashboard.total : nil }
    private var periodSelection: Binding<UsagePeriod> {
        Binding(get: { state.period }, set: {
            state.period = $0
            state.filters.occurredFrom = nil; state.filters.occurredBefore = nil

        })
    }
    private var rangeLabel: String {
        if state.filters.occurredFrom != nil || state.filters.occurredBefore != nil {
            return "\(UsageFormatting.timestamp(state.filters.occurredFrom, timezone: timezone)) — \(UsageFormatting.timestamp(state.filters.occurredBefore, timezone: timezone))"
        }
        if state.period == .all {
            guard state.dashboard.loadedQuery == query,
                  let from = state.dashboard.dataFromDate, let through = state.dashboard.dataThroughDate else { return "—" }
            return "\(from) — \(through)"
        }
        return "\(query.fromDate ?? "—") — \(query.throughDate ?? "—")"
    }
    private func restore(_ original: UsageQuery) {
        var request = original
        if case .value(let day) = request.filters.day {
            request.fromDate = day; request.throughDate = day
            request.filters.day = .all
            request.filters.occurredFrom = nil; request.filters.occurredBefore = nil
        }
        state.grouping = request.grouping == .thread ? .thread : request.grouping == .project ? .project : .day
        state.filters = request.filters; state.account = request.account; state.sort = request.sort; state.page = request.offset / 100
        state.selectedRow = nil
        var restored = request; restored.offset = 0
        state.restoredCriteria = restored
        let style = Date.ISO8601FormatStyle(timeZone: timezone).year().month().day().dateSeparator(.dash)
        if let from = request.fromDate, let through = request.throughDate,
           let start = try? style.parse(from), let end = try? style.parse(through) {
            state.customFrom = start; state.customThrough = end
            state.period = [UsagePeriod.today, .week, .month, .quarter, .year].first {
                let dates = $0.dates(timezone: timezone)
                return dates.0 == from && dates.1 == through
            } ?? .custom
        } else { state.period = .all }
    }
}

struct AccountScopeControl: View {
    @Binding var account: UsageAccountScope
    var accounts: [String] = []
    var currentAccount: String?
    private var available: [String] {
        var result = Set(accounts)
        if let currentAccount { result.insert(currentAccount) }
        if case .account(let id) = account, !id.isEmpty { result.insert(id) }
        return result.sorted()
    }
    var body: some View {
        Group {
            if available.count > 1 {
                Picker("账号", selection: $account) {
                    Text("全部账号").tag(UsageAccountScope.all)
                    ForEach(available, id: \.self) { id in
                        Text(id == currentAccount ? "当前账号" : "账号 · " + String(id.suffix(8)))
                            .help(id).tag(UsageAccountScope.account(id))
                    }
                }.labelsHidden().frame(width: 160)
            }
        }
        .onChange(of: available, initial: true) {
            if account == .unknown || available.count <= 1 { account = .all }
        }
    }
}
