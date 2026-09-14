import TokenTickCore
import SwiftUI

private enum AppPage: String, CaseIterable, Identifiable {
    case overview = "总览", usage = "用量明细", limits = "套餐用量"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .overview: "chart.pie"
        case .usage: "tablecells"
        case .limits: "gauge.with.dots.needle.33percent"
        }
    }
}

struct ContentView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(ApplicationModel.self) private var app
    @Environment(\.openSettings) private var openSettings
    @SceneStorage("main.page") private var selectedPage = AppPage.overview.rawValue
    @State private var showingSync = false
    @State private var detailRequest: UsageQuery?
    @State private var usageState = UsageDetailsState()
    private var page: AppPage { AppPage(rawValue: selectedPage) ?? .overview }
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 10) {
                    Image("BrandIcon").resizable().frame(width: 30, height: 30)
                    Text("TokenTick").font(.system(size: 18, weight: .semibold))
                }.padding(.horizontal, 12).padding(.top, 18)
                VStack(spacing: 6) {
                    ForEach(AppPage.allCases) { item in
                        Button { selectedPage = item.rawValue } label: {
                            Label(item.rawValue, systemImage: item.symbol)
                                .font(.system(size: 14, weight: page == item ? .semibold : .medium))
                                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                .background(page == item ? Color.primary.opacity(0.08) : .clear,
                                            in: RoundedRectangle(cornerRadius: 12))
                        }.buttonStyle(.plain).accessibilityAddTraits(page == item ? .isSelected : [])
                    }
                }
                Spacer()
                SettingsLink { Label("设置", systemImage: "gearshape").frame(maxWidth: .infinity, alignment: .leading).padding(12) }
                    .buttonStyle(.plain)
            }.padding(14)
            .navigationSplitViewColumnWidth(min: 185, ideal: 210, max: 250)
        } detail: {
            VStack(spacing: 0) {
                if app.store == nil {
                    ContentUnavailableView {
                        Label(app.error == nil ? "正在打开数据库" : "无法打开数据库", systemImage: "externaldrive")
                    } actions: {
                        if app.error != nil { Button("重试") { Task { await app.start() } } }
                    }
                } else {
                    switch page {
                    case .overview:
                        OverviewView { query in detailRequest = query; selectedPage = AppPage.usage.rawValue }
                    case .usage: UsageDetailsView(initialQuery: $detailRequest, state: usageState)
                    case .limits: LimitsView()
                    }
                }
            }
            .background(scheme == .dark ? Color.black.opacity(0.5) : Color.white.opacity(0.2))
            .navigationTitle(page.rawValue)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Text(syncTime(now: context.date)).font(.caption).foregroundStyle(.secondary)
                            .help(UsageFormatting.timestamp(app.lastSync?.finishedAt))
                    }
                }.sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        if app.isSyncing || app.error != nil || !(app.lastSync?.issues.isEmpty ?? true) { showingSync = true }
                        else { app.synchronize() }
                    } label: {
                        ZStack {
                            Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 14, weight: .medium)).opacity(app.isSyncing ? 0 : 1)
                            if app.isSyncing { ProgressView().controlSize(.small) }
                        }.frame(width: 28, height: 28).accessibilityLabel("刷新")
                    }.popover(isPresented: $showingSync) {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("同步").font(.headline)
                            if let finished = app.lastSync?.finishedAt {
                                LabeledContent("上次同步", value: UsageFormatting.timestamp(finished))
                            }
                            if app.isSyncing {
                                Text(app.progressText).foregroundStyle(.secondary)
                                if app.progress?.stage != .statistics { Button("取消同步") { app.cancelSync() } }
                            }
                            if let error = app.error { Text(error).foregroundStyle(.secondary) }
                            if let issues = app.lastSync?.issues, !issues.isEmpty {
                                Text("\(issues.count) 项同步问题").foregroundStyle(.secondary)
                            }
                            if !app.isSyncing { Button("重新同步") { showingSync = false; app.synchronize() } }
                            Button("查看数据状态") { showingSync = false; app.settingsSection = "数据状态"; openSettings() }
                        }.padding(22).frame(width: 320)
                    }
                    .disabled(app.store == nil).keyboardShortcut("r")
                }
            }
        }
        .containerBackground(.thinMaterial, for: .window)
        .tint(.primary)
        .frame(minWidth: 940, minHeight: 640)
        .task { await app.start() }
    }
    private func syncTime(now: Date) -> String {
        guard let finished = app.lastSync?.finishedAt else { return "尚未同步" }
        let minutes = max(0, Int((now.timeIntervalSince1970 - finished) / 60))
        if minutes == 0 { return "上次同步 刚刚" }
        if minutes < 60 { return "上次同步 \(minutes) 分钟前" }
        if minutes < 1440 { return "上次同步 \(minutes / 60) 小时前" }
        return "上次同步 \(minutes / 1440) 天前"
    }

}

#Preview { ContentView().environment(ApplicationModel()) }

struct LumaSurface: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content.padding(24)
            .background(scheme == .dark ? Color.white.opacity(0.045) : Color.white.opacity(0.68),
                        in: RoundedRectangle(cornerRadius: 22))
            .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(Color.primary.opacity(0.055)).allowsHitTesting(false) }
            .shadow(color: .black.opacity(scheme == .dark ? 0.09 : 0.025), radius: 12, y: 4)
    }
}
