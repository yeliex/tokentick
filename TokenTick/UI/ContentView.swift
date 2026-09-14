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
    @SceneStorage("main.page") private var selectedPage = AppPage.overview.rawValue
    @State private var detailRequest: UsageQuery?
    @State private var usageState = UsageDetailsState()
    @State private var limitsState = LimitsPageState()
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
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityAddTraits(page == item ? .isSelected : [])
                    }
                }
                Spacer()
                SettingsLink {
                    Label("设置", systemImage: "gearshape")
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        .contentShape(Rectangle())
                }
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
                    case .limits: LimitsView(state: limitsState)
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
                    Button("刷新", systemImage: "arrow.triangle.2.circlepath") {
                        app.synchronize()
                    }
                    .labelStyle(.iconOnly)
                    .help(app.isSyncing ? "正在同步" : "刷新")
                    .disabled(app.store == nil || app.isSyncing).keyboardShortcut("r")
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
