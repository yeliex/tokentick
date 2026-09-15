import SwiftUI
import ServiceManagement
import TokenTickCore
import TokenTickUpdates

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "通用", data = "数据", about = "关于"
    var id: Self { self }
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
                    Label(section.rawValue, systemImage: section.symbol)
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
            Section("启动") {
                Toggle("开机启动", isOn: Binding(
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
                    Button("在系统设置中允许开机启动") { SMAppService.openSystemSettingsLoginItems() }
                }
                if let loginError { Text(loginError).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            Section("额度显示") {
                Picker("显示方式", selection: $limitsShowRemaining) {
                    Text("剩余").tag(true)
                    Text("已使用").tag(false)
                }.pickerStyle(.segmented)
                Picker("每周工作日刻度", selection: $limitsWorkingDays) {
                    Text("4 天").tag(4)
                    Text("5 天").tag(5)
                    Text("7 天").tag(7)
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
                    Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ApplicationInfo.version)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(.primary.opacity(0.05), in: Capsule())
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 16)

                VStack(spacing: 12) {
                    Toggle("自动检查更新", isOn: Binding(
                        get: { updates.automaticallyChecksForUpdates },
                        set: { updates.setAutomaticallyChecksForUpdates($0) }
                    ))
                    Button("检查更新…", action: updates.checkForUpdates)
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
