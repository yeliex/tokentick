import SwiftUI
import ServiceManagement
import TokenTickCore
import TokenTickUpdates

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "通用", data = "数据", about = "关于"
    var id: Self { self }
    // 保留原始值供偏好存储使用，展示名称随系统语言本地化。
    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .data: String(localized: "Data")
        case .about: String(localized: "About")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .data: "externaldrive"
        case .about: "info.circle"
        }
    }
}

struct SettingsView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(ApplicationModel.self) private var app
    @State private var selection: SettingsSection? = .general

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(SettingsSection.allCases, selection: $selection) { section in
                NavigationLink(value: section) {
                    Label(section.title, systemImage: section.symbol)
                }
            }
            .toolbar(removing: .sidebarToggle)
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 150, ideal: 176, max: 210)
            .scrollContentBackground(.hidden)
        } detail: {
            Group {
                switch selection ?? .general {
                case .general: GeneralSettingsView()
                case .data: Form { DataStatusView() }.formStyle(.grouped)
                case .about: AboutSettingsView()
                }
            }
            .navigationTitle("")
            .scrollContentBackground(.hidden)
            .background(scheme == .dark ? Color.black.opacity(0.5) : Color.white.opacity(0.2))
        }
        .navigationSplitViewStyle(.balanced)
        .frame(width: 760, height: 640)
        .containerBackground(.thinMaterial, for: .window)
        .tint(.primary)
        .task { await app.start() }
    }
}

private struct GeneralSettingsView: View {
    @AppStorage("limitsShowRemaining") private var limitsShowRemaining = true
    @AppStorage("limitsWorkingDays") private var limitsWorkingDays = 5
    @Environment(\.scenePhase) private var scenePhase
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?

    var body: some View {
        Form {
            Section(String(localized: "Startup")) {
                Toggle(String(localized: "Launch at login"), isOn: Binding(
                    get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                    set: { enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch { loginError = error.localizedDescription }
                        loginStatus = SMAppService.mainApp.status
                    }
                ))
                if loginStatus == .requiresApproval {
                    Button(String(localized: "Allow launch at login in System Settings")) { SMAppService.openSystemSettingsLoginItems() }
                }
                if let loginError { Text(loginError).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            Section(String(localized: "Limit display")) {
                Picker(String(localized: "Display"), selection: $limitsShowRemaining) {
                    Text(String(localized: "remaining")).tag(true)
                    Text(String(localized: "used")).tag(false)
                }.pickerStyle(.segmented)
                Picker(String(localized: "Working days per week"), selection: $limitsWorkingDays) {
                    Text(String(localized: "4 days")).tag(4)
                    Text(String(localized: "5 days")).tag(5)
                    Text(String(localized: "7 days")).tag(7)
                }.pickerStyle(.segmented)
            }
        }
        .formStyle(.grouped)
        .onAppear { loginStatus = SMAppService.mainApp.status }
        .onChange(of: scenePhase) {
            if scenePhase == .active { loginStatus = SMAppService.mainApp.status }
        }
    }
}

private struct AboutSettingsView: View {
    @EnvironmentObject private var updates: UpdateController

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                VStack(spacing: 12) {
                    Image("BrandIcon")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 88, height: 88)
                        .accessibilityHidden(true)
                    Text(ApplicationInfo.name)
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                    Text(String(localized: "Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ApplicationInfo.version)"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(.primary.opacity(0.05), in: Capsule())
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 16)

                VStack(spacing: 12) {
                    Toggle(String(localized: "Check for updates automatically"), isOn: Binding(
                        get: { updates.automaticallyChecksForUpdates },
                        set: { updates.setAutomaticallyChecksForUpdates($0) }
                    ))
                    Button(String(localized: "Check for Updates…"), action: updates.checkForUpdates)
                        .disabled(!updates.canCheckForUpdates)
                }

                StorageSettingsView()
            }
            .frame(maxWidth: 520)
            .padding(28)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
