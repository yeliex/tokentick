import TokenTickCore
import SwiftUI

struct ContentView: View {
    @Environment(ApplicationModel.self) private var app
    @SceneStorage("navigation.selection") private var selectedSection = NavigationSection.overview.rawValue
    @State private var period = UsagePeriod.month
    @State private var dashboard = DashboardModel()
    @State private var page = 0
    @State private var selectedRow: String?

    private var section: NavigationSection { NavigationSection(rawValue: selectedSection) ?? .overview }
    private var queryKey: String { "\(selectedSection)/\(period.rawValue)/\(page)/\(app.refreshID)" }
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
                if let error = dashboard.error ?? app.error {
                    Label(error, systemImage: "exclamationmark.triangle").font(.callout)
                        .foregroundStyle(.secondary).textSelection(.enabled).padding(12)
                }
                content
            }
            .navigationTitle(section.title)
            .toolbar {
                if section != .limits && section != .data {
                    Picker("日期范围", selection: $period) {
                        ForEach(UsagePeriod.allCases) { Text($0.rawValue).tag($0) }
                    }.frame(width: 130)
                }
                Button { app.synchronize() } label: { Label("同步", systemImage: "arrow.triangle.2.circlepath") }
                    .disabled(app.isSyncing || app.store == nil).keyboardShortcut("r")
            }
            .overlay(alignment: .topTrailing) {
                if dashboard.loading { ProgressView().controlSize(.small).padding(12).allowsHitTesting(false) }
            }
        }
        .inspector(isPresented: Binding(get: { selectedRow != nil }, set: { if !$0 { selectedRow = nil } })) {
            if let row = dashboard.rows.first(where: { $0.id == selectedRow }) {
                UsageSummaryInspector(row: row).inspectorColumnWidth(min: 280, ideal: 320, max: 360)
            }
        }
        .frame(minWidth: 860, minHeight: 580)
        .task { await app.start() }
        .task(id: queryKey) {
            guard let store = app.store else { return }
            await dashboard.load(store: store, section: section, period: period,
                                 timezone: app.status?.timezone ?? "UTC", page: page)
        }
        .onChange(of: selectedSection) { page = 0; selectedRow = nil }
        .onChange(of: period) { page = 0; selectedRow = nil }
    }

    @ViewBuilder private var content: some View {
        if app.store == nil {
            ContentUnavailableView {
                Label(app.error == nil ? "正在打开数据库" : "无法打开数据库", systemImage: "externaldrive")
            } actions: {
                if app.error != nil { Button("重试") { Task { await app.start() } } }
            }
        } else if section == .data {
            DataStatusView(days: dashboard.apiDays, models: dashboard.models)
        } else if section == .limits {
            LimitsView(windows: dashboard.limits)
        } else if dashboard.total == nil && !dashboard.loading {
            ContentUnavailableView("所选范围暂无用量", systemImage: section.symbol,
                                   description: Text("同步本地日志，或选择其他日期范围。"))
        } else if section == .overview {
            OverviewView(model: dashboard, timezone: app.status?.timezone ?? "UTC")
        } else {
            VStack(spacing: 0) {
                HStack {
                    Text(app.status?.timezone ?? "UTC").foregroundStyle(.secondary)
                    Spacer()
                    Text("\(UsageFormatting.tokens(dashboard.total?.totalTokens)) tokens").monospacedDigit()
                }.font(.callout).padding(16)
                if section == .daily { UsageTrendView(days: dashboard.days).padding(.horizontal, 24).padding(.bottom, 18) }
                UsageTableView(rows: dashboard.rows, isThread: section == .threads, selection: $selectedRow, page: $page)
            }
        }
    }
}

#Preview { ContentView().environment(ApplicationModel()) }
