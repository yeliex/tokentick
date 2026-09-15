import TokenTickCore
import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @Environment(ApplicationModel.self) private var app

    private var email: String? {
        guard let account = app.currentLimits?.accountID,
              let report = app.status?.apiLastReport, report.accountID == account else { return nil }
        return report.accountEmail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if subscriptionLoading {
                ProgressView("正在读取订阅与额度…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 100)
            } else {
                if app.currentLimits != nil {
                    subscriptionHeader
                    Divider()
                }
                CurrentLimitsView(compact: true)
                    .padding(.bottom, -6)
            }
            Divider()
            MenuUsageView()
            Divider()
            VStack(spacing: 0) {
                ForEach(AppPage.allCases) { page in
                    Button {
                        dismiss()
                        app.requestedPage = page
                        NSApp.setActivationPolicy(.regular)
                        openWindow(id: "main")
                        NSApp.activate(ignoringOtherApps: true)
                    } label: { menuLabel(page.rawValue, symbol: page.symbol) }
                }
                Button { NSApp.terminate(nil) } label: {
                    menuLabel("退出", symbol: "rectangle.portrait.and.arrow.right", showsChevron: false)
                }.keyboardShortcut("q")
            }.buttonStyle(MenuRowButtonStyle())
                .padding(.horizontal, -10)
            if let error = app.error {
                Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(2).help(error)
            }
        }.padding(16)
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
        .background(.ultraThinMaterial)
        .background {
            MainWindowSettingsButton().frame(width: 0, height: 0).clipped().opacity(0).accessibilityHidden(true)
        }
        .task { await app.start(); await app.refreshExpiredLimits() }
    }

    private var subscriptionLoading: Bool {
        (app.currentLimits == nil || email == nil) && (app.isSyncing || app.store == nil && app.error == nil)
    }

    private var subscriptionHeader: some View {
        HStack(spacing: 10) {
            Image("BrandIcon").resizable().frame(width: 30, height: 30)
            VStack(spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Codex").font(.headline).fixedSize()
                    Spacer(minLength: 0)
                    if let email {
                        Text(email).font(.caption).lineLimit(1).truncationMode(.middle).help(email)
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Text(syncStatus(now: context.date))
                            .lineLimit(1)
                            .help(app.isSyncing ? app.progressText : UsageFormatting.timestamp(app.lastSync?.finishedAt))
                    }
                    Spacer(minLength: 0)
                    if let plan = app.currentLimits?.planType {
                        Text(CurrentLimitsView.planName(plan) ?? plan).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                    }
                }.font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func syncStatus(now: Date) -> String {
        if app.isSyncing { return "同步中…" }
        if app.error != nil { return "同步失败" }
        if let observed = app.currentLimits?.observedAt, now.timeIntervalSince1970 - observed > 900 {
            return "额度已过期"
        }
        guard let finished = app.lastSync?.finishedAt else { return "尚未同步" }
        let minutes = max(0, Int(now.timeIntervalSince1970 - finished) / 60)
        if minutes == 0 { return "刚刚同步" }
        if minutes < 60 { return "\(minutes) 分钟前同步" }
        if minutes < 1440 { return "\(minutes / 60) 小时前同步" }
        return "\(minutes / 1440) 天前同步"
    }

    private func menuLabel(_ title: String, symbol: String, showsChevron: Bool = true) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).frame(width: 20)
            Text(title)
            Spacer(minLength: 0)
            if showsChevron {
                Image(systemName: "chevron.right").font(.caption2).opacity(0.5)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
    }
}

private struct MenuRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    private struct Row: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovered = false
        private var highlighted: Bool { isEnabled && (hovered || configuration.isPressed) }

        var body: some View {
            configuration.label
                .foregroundStyle(highlighted ? Color.white : Color.primary)
                .background(highlighted ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 5))
                .opacity(isEnabled ? 1 : 0.5)
                .onHover { hovered = $0 }
        }
    }
}
