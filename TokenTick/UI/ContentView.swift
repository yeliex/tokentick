import TokenTickCore
import SwiftUI

enum AppPage: String, CaseIterable, Identifiable {
    case overview = "总览", usage = "用量明细", limits = "套餐用量"
    var id: Self { self }
    // 保留原始值供偏好存储使用，展示名称随系统语言本地化。
    var title: String {
        switch self {
        case .overview: String(localized: "Overview")
        case .usage: String(localized: "Usage details")
        case .limits: String(localized: "Plan usage")
        }
    }

    var symbol: String {
        switch self {
        case .overview: "chart.pie"
        case .usage: "tablecells"
        case .limits: "gauge.with.dots.needle.33percent"
        }
    }
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
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
                            Label(item.title, systemImage: item.symbol)
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
                    Label(String(localized: "Settings"), systemImage: "gearshape")
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
                        Label(app.error == nil ? String(localized: "Opening database") : String(localized: "Unable to open database"), systemImage: "externaldrive")
                    } actions: {
                        if app.error != nil { Button(String(localized: "Retry")) { Task { await app.start() } } }
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
            .navigationTitle(page.title)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Text(app.isSyncing ? app.progressText : syncTime(now: context.date))
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                            .help(app.isSyncing ? app.progressText : UsageFormatting.timestamp(app.lastSync?.finishedAt))
                    }
                }.sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        app.synchronize()
                    } label: {
                        Group {
                            if app.isSyncing {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                            }
                        }.frame(width: 16, height: 16)
                    }
                    .accessibilityLabel(app.isSyncing ? String(localized: "Syncing") : String(localized: "Refresh"))
                    .help(app.isSyncing ? String(localized: "Syncing") : String(localized: "Refresh"))
                    .disabled(app.store == nil || app.isSyncing).keyboardShortcut("r")
                }
            }
        }
        .containerBackground(.thinMaterial, for: .window)
        .tint(.primary)
        .frame(minWidth: 940, minHeight: 640)
        .task { await app.start(); consumePageRequest() }
        .onChange(of: app.requestedPage) { consumePageRequest() }
        .task(id: scenePhase) {
            if scenePhase == .active { await app.refreshExpiredLimits() }
        }
    }
    private func consumePageRequest() {
        guard let requested = app.requestedPage else { return }
        selectedPage = requested.rawValue
        app.requestedPage = nil
    }
    private func syncTime(now: Date) -> String {
        guard let finished = app.lastSync?.finishedAt else { return String(localized: "Not synced yet") }
        let minutes = max(0, Int((now.timeIntervalSince1970 - finished) / 60))
        if minutes == 0 { return String(localized: "Last synced just now") }
        if minutes < 60 { return String(localized: "Last synced \(minutes) min ago") }
        if minutes < 1440 { return String(localized: "Last synced \(minutes / 60) hr ago") }
        return String(localized: "Last synced \(minutes / 1440)d ago")
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
