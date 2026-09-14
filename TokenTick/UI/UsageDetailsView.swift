import SwiftUI
import TokenTickCore
import Observation

@MainActor @Observable
final class UsageDetailsState {
    var section = NavigationSection.daily
    var period = UsagePeriod.month
    var dashboard = DashboardModel()
    var page = 0
    var selectedRow: String?
    var filters = UsageFilters()
    var account: UsageAccountScope = .all
    var sort = UsageSort.automatic
    var customFrom = Date()
    var customThrough = Date()
    var showingFilters = false
    var records: UsageRecordDestination?
    var backstack: [UsageQuery] = []
    var restoredCriteria: UsageQuery?
}

struct UsageRecordDestination { let title: String; let query: UsageQuery }


struct UsageDetailsView: View {
    @Environment(ApplicationModel.self) private var app
    @Binding var initialQuery: UsageQuery?
    @Bindable var state: UsageDetailsState
    private struct Request: Hashable { let section: NavigationSection; let query: UsageQuery; let refresh: Int }
    private var timezone: TimeZone { TimeZone(identifier: app.status?.timezone ?? "UTC") ?? .gmt }
    private var query: UsageQuery {
        let style = Date.ISO8601FormatStyle(timeZone: timezone).year().month().day().dateSeparator(.dash)
        let dates = state.period == .custom ? (state.customFrom.formatted(style), state.customThrough.formatted(style)) : state.period.dates(timezone: timezone)
        return UsageQuery(grouping: state.section == .threads ? .thread : state.section == .projects ? .project : .day,
            timezone: timezone.identifier, fromDate: dates.0, throughDate: dates.1, account: state.account,
            limit: 100, offset: state.page * 100, filters: state.filters, sort: state.sort)
    }
    var body: some View {
        VStack(spacing: 0) {
            if let records = state.records {
                UsageRecordsView(title: records.title, query: records.query, scope: .all, onClose: { state.records = nil })
            } else {
                HStack {
                    if !state.backstack.isEmpty {
                        Button { if let previous = state.backstack.popLast() { restore(previous) } } label: {
                            Label("返回", systemImage: "chevron.left")
                        }
                    }
                    Picker("聚合方式", selection: $state.section) {
                        Text("每日").tag(NavigationSection.daily)
                        Text("项目").tag(NavigationSection.projects)
                        Text("任务").tag(NavigationSection.threads)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 240)
                    Spacer()
                    Picker("日期范围", selection: periodSelection) {
                        ForEach(UsagePeriod.allCases) { Text($0.rawValue).tag($0) }
                    }.labelsHidden().frame(width: 145)
                    Button { state.showingFilters.toggle() } label: { Label("筛选", systemImage: "line.3.horizontal.decrease") }
                        .popover(isPresented: $state.showingFilters) {
                            VStack {
                                AccountScopeControl(account: $state.account).padding()
                                UsageFilterControls(filters: $state.filters, period: periodSelection, from: $state.customFrom,
                                                    through: $state.customThrough, timezone: timezone)
                            }
                        }
                }.padding(.vertical, 8).padding(.bottom, 16)
                HStack {
                    TextField("搜索任务标题或 ID", text: $state.filters.search).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                    Spacer()
                    Picker("排序", selection: $state.sort) {
                        ForEach(UsageSort.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.labelsHidden().frame(width: 180)
                }.padding(.horizontal, 4).padding(.bottom, 12)
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(rangeLabel)
                        if !state.filters.summary.isEmpty { Text(state.filters.summary).lineLimit(2) }
                        Text(accountLabel)
                    }.font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if !state.filters.isEmpty || state.account != .all {
                        Button("清除筛选") { state.filters = UsageFilters(); state.account = .all }.buttonStyle(.borderless)
                    }
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("\(UsageFormatting.tokens(currentTotal?.totalTokens)) Tokens").monospacedDigit()
                        Text("预估费用 \(UsageFormatting.money(currentTotal?.knownAmountNanoUSD))")
                            .foregroundStyle(.secondary).font(.caption).monospacedDigit()
                    }
                }.padding(.horizontal, 4).padding(.bottom, 14)
                if let error = state.dashboard.error {
                    ContentUnavailableView("查询失败", systemImage: "exclamationmark.triangle", description: Text(error))
                } else if state.dashboard.loadedQuery != query || state.dashboard.loadedSection != state.section {
                    ProgressView("正在查询用量").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    UsageTableView(rows: state.dashboard.rows, isThread: state.section == .threads,
                                   hasMore: state.dashboard.hasMore, selection: $state.selectedRow, page: $state.page)
                        .overlay {
                            if state.dashboard.rows.isEmpty { ContentUnavailableView("所选范围暂无用量", systemImage: "tablecells") }
                        }
                }
            }
        }
        .padding(24)
        .inspector(isPresented: Binding(get: { state.selectedRow != nil && state.records == nil }, set: { if !$0 { state.selectedRow = nil } })) {
            if state.dashboard.loadedQuery == query, let row = state.dashboard.rows.first(where: { $0.id == state.selectedRow }) {
                UsageSummaryInspector(row: row, query: query.focused(on: query.grouping, value: row.summary.group),
                    openRecords: { focused in state.records = UsageRecordDestination(title: row.title, query: focused); state.selectedRow = nil }) { target, focused in
                        state.backstack.append(query)
                        var next = focused
                        next.grouping = target == .threads ? .thread : target == .projects ? .project : .day
                        restore(next)
                    }
                    .id(query.focused(on: query.grouping, value: row.summary.group))
                    .inspectorColumnWidth(min: 280, ideal: 320, max: 380)
            }
        }
        .task {
            if let initialQuery {
                state.records = nil; state.backstack = []
                restore(initialQuery); self.initialQuery = nil
            }
        }
        .task(id: Request(section: state.section, query: query, refresh: app.usageRefreshID)) {
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let store = app.store else { return }
            await state.dashboard.load(store: store, section: state.section, query: query)
        }
        .onChange(of: criteria) {
            if state.restoredCriteria == criteria { state.restoredCriteria = nil; return }
            state.page = 0; state.selectedRow = nil
        }

    }
    private var criteria: UsageQuery { var value = query; value.offset = 0; return value }
    private var currentTotal: UsageSummary? { state.dashboard.loadedQuery == query ? state.dashboard.total : nil }
    private var periodSelection: Binding<UsagePeriod> {
        Binding(get: { state.period }, set: {
            state.period = $0
            state.filters.occurredFrom = nil; state.filters.occurredBefore = nil
            if $0 == .custom { state.showingFilters = true }
        })
    }
    private var rangeLabel: String {
        if state.filters.occurredFrom != nil || state.filters.occurredBefore != nil {
            return "\(UsageFormatting.timestamp(state.filters.occurredFrom, timezone: timezone)) — \(UsageFormatting.timestamp(state.filters.occurredBefore, timezone: timezone)) · \(timezone.identifier)"
        }
        return "\(query.fromDate ?? "最早") — \(query.throughDate ?? "至今") · \(timezone.identifier)"
    }
    private var accountLabel: String {
        switch state.account { case .all: "全部账号"; case .unknown: "未知账号"; case .account(let id): "账号：\(id)" }
    }
    private func restore(_ request: UsageQuery) {
        state.section = request.grouping == .thread ? .threads : request.grouping == .project ? .projects : .daily
        state.filters = request.filters; state.account = request.account; state.sort = request.sort; state.page = request.offset / 100
        state.selectedRow = nil
        var restored = request; restored.offset = 0
        state.restoredCriteria = restored
        let style = Date.ISO8601FormatStyle(timeZone: timezone).year().month().day().dateSeparator(.dash)
        if let from = request.fromDate, let through = request.throughDate,
           let start = try? style.parse(from), let end = try? style.parse(through) {
            state.customFrom = start; state.customThrough = end; state.period = .custom
        } else { state.period = .all }
    }
}

struct AccountScopeControl: View {
    @Binding var account: UsageAccountScope
    private var mode: Binding<Int> {
        Binding(get: { switch account { case .all: 0; case .unknown: 1; case .account: 2 } },
                set: { account = $0 == 0 ? .all : $0 == 1 ? .unknown : .account("") })
    }
    var body: some View {
        VStack(alignment: .leading) {
            Picker("账号", selection: mode) { Text("全部").tag(0); Text("未知").tag(1); Text("指定账号").tag(2) }
            if case .account(let id) = account {
                TextField("账号 ID", text: Binding(get: { id }, set: { account = .account($0) })).textFieldStyle(.roundedBorder)
            }
        }
    }
}
