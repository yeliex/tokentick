import TokenTickCore
import SwiftUI

struct ContentView: View {
    @Environment(ApplicationModel.self) private var app
    @SceneStorage("navigation.selection") private var selectedSection = NavigationSection.overview.rawValue
    @State private var period = UsagePeriod.month
    @State private var dashboard = DashboardModel()
    @State private var page = 0
    @State private var selectedRow: String?
    @State private var filters = UsageFilters()
    @State private var sort = UsageSort.automatic
    @State private var customFrom = Date()
    @State private var customThrough = Date()
    @State private var showingFilters = false

    private var section: NavigationSection { NavigationSection(rawValue: selectedSection) ?? .overview }
    private var timezone: TimeZone { TimeZone(identifier: app.status?.timezone ?? "UTC") ?? .gmt }
    private var isUsage: Bool { section != .data && section != .limits }
    private var query: UsageQuery {
        let style = Date.ISO8601FormatStyle(timeZone: timezone).year().month().day().dateSeparator(.dash)
        let dates = period == .custom ? (customFrom.formatted(style), customThrough.formatted(style)) : period.dates(timezone: timezone)
        return UsageQuery(grouping: section == .threads ? .thread : section == .projects ? .project : .day,
            timezone: timezone.identifier, fromDate: isUsage ? dates.0 : nil, throughDate: isUsage ? dates.1 : nil,
            limit: 100, offset: page * 100, filters: isUsage ? filters : UsageFilters(), sort: sort)
    }
    private struct Request: Hashable {
        let section: String
        let query: UsageQuery
        let refresh: Int
    }
    private var request: Request { Request(section: selectedSection, query: query, refresh: app.refreshID) }
    private var selection: Binding<NavigationSection?> {
        Binding(get: { section }, set: { if let value = $0 { selectedSection = value.rawValue } })
    }

    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                Section("用量") {
                    ForEach([NavigationSection.overview, .daily, .threads, .projects]) { item in
                        Label(item.title, systemImage: item.symbol).tag(item)
                    }
                }
                Section("记录") {
                    ForEach([NavigationSection.limits, .data]) { item in
                        Label(item.title, systemImage: item.symbol).tag(item)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle(ApplicationInfo.name)
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
        } detail: {
            VStack(spacing: 0) {
                if app.isSyncing {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(app.progressText).font(.callout)
                        Spacer()
                        if app.progress?.stage != .statistics {
                            Button("取消") { app.cancelSync() }.buttonStyle(.borderless)
                        }
                    }.padding(12)
                    Divider()
                }
                if let error = (section == .limits ? nil : dashboard.error) ?? app.error {
                    Label(error, systemImage: "exclamationmark.triangle").font(.callout)
                        .foregroundStyle(.secondary).textSelection(.enabled).padding(12)
                }
                if isUsage {
                    HStack {
                        Text("\(query.fromDate ?? "最早") — \(query.throughDate ?? "至今") · \(timezone.identifier)")
                        if !filters.summary.isEmpty { Text(filters.summary).lineLimit(1).help(filters.summary) }
                        Spacer()
                        if !filters.isEmpty { Button("清除筛选") { filters = UsageFilters() }.buttonStyle(.borderless) }
                    }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 8)
                    Divider()
                }
                content
            }
            .navigationTitle(section.title)
            .toolbar {
                if isUsage {
                    Picker("日期范围", selection: $period) {
                        ForEach(UsagePeriod.allCases) { Text($0.rawValue).tag($0) }
                    }.frame(width: 130).accessibilityLabel("日期范围")
                    TextField("搜索任务标题或 ID", text: $filters.search)
                        .textFieldStyle(.roundedBorder).frame(width: 180)
                    Button { showingFilters.toggle() } label: { Label("筛选", systemImage: "line.3.horizontal.decrease") }
                        .popover(isPresented: $showingFilters) {
                            UsageFilterControls(filters: $filters, period: $period, from: $customFrom,
                                through: $customThrough, timezone: timezone)
                        }
                    Picker("排序", selection: $sort) {
                        ForEach(UsageSort.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.frame(width: 155).accessibilityLabel("排序")
                }
                Button { app.synchronize() } label: { Label("同步", systemImage: "arrow.triangle.2.circlepath") }
                    .disabled(app.isSyncing || app.store == nil).keyboardShortcut("r")
            }
            .overlay(alignment: .topTrailing) {
                if section != .limits && dashboard.loading { ProgressView().controlSize(.small).padding(12).allowsHitTesting(false) }
            }
        }
        .inspector(isPresented: Binding(get: { selectedRow != nil }, set: { if !$0 { selectedRow = nil } })) {
            if dashboard.loadedQuery == query && dashboard.loadedSection == section, let row = dashboard.rows.first(where: { $0.id == selectedRow }) {
                UsageSummaryInspector(row: row, query: query.focused(on: query.grouping, value: row.summary.group), scope: .all) { target, focused in
                    filters = focused.filters
                    selectedSection = target.rawValue
                    selectedRow = nil; page = 0
                }
                .id(request.query.focused(on: query.grouping, value: row.summary.group))
                .inspectorColumnWidth(min: 280, ideal: 320, max: 380)
            }
        }
        .frame(minWidth: 860, minHeight: 580)
        .task { await app.start() }
        .task(id: request) {
            // 输入期间取消尚未开始的查询，避免每个按键都聚合历史事实。
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard section != .limits, let store = app.store else { return }
            await dashboard.load(store: store, section: section, query: query)
        }
        .onChange(of: selectedSection) { page = 0; selectedRow = nil }
        .onChange(of: period) {
            page = 0; selectedRow = nil
            if period == .custom { showingFilters = true }
        }
        .onChange(of: filters) { page = 0; selectedRow = nil }
        .onChange(of: sort) { page = 0; selectedRow = nil }
        .onChange(of: customFrom) { page = 0; selectedRow = nil }
        .onChange(of: customThrough) { page = 0; selectedRow = nil }
    }

    @ViewBuilder private var content: some View {
        if app.store == nil {
            ContentUnavailableView {
                Label(app.error == nil ? "正在打开数据库" : "无法打开数据库", systemImage: "externaldrive")
            } actions: {
                if app.error != nil { Button("重试") { Task { await app.start() } } }
            }
        } else if section == .limits {
            LimitsView()
        } else if dashboard.loadedQuery != query || dashboard.loadedSection != section {
            ProgressView("正在查询用量").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if section == .data {
            DataStatusView(days: dashboard.apiDays, models: dashboard.models)
        } else if dashboard.total == nil && !dashboard.loading {
            ContentUnavailableView("所选范围暂无用量", systemImage: section.symbol,
                                   description: Text("同步本地日志，或选择其他日期范围。"))
        } else if section == .overview {
            OverviewView(model: dashboard, timezone: timezone.identifier) { grouping, value in
                filters = query.focused(on: grouping, value: value).filters
                selectedSection = NavigationSection.threads.rawValue
            }
        } else {
            VStack(spacing: 0) {
                HStack {
                    Text(app.status?.timezone ?? "UTC").foregroundStyle(.secondary)
                    Spacer()
                    Text("\(UsageFormatting.tokens(dashboard.total?.totalTokens)) tokens").monospacedDigit()
                }.font(.callout).padding(16)
                if section == .daily {
                    UsageTrendView(days: dashboard.days) { date in
                        filters = query.focused(on: .day, value: date).filters
                        selectedSection = NavigationSection.threads.rawValue
                    }.padding(.horizontal, 24).padding(.bottom, 18)
                }
                UsageTableView(rows: dashboard.rows, isThread: section == .threads, hasMore: dashboard.hasMore, selection: $selectedRow, page: $page)
            }
        }
    }
}

#Preview { ContentView().environment(ApplicationModel()) }
