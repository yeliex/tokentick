import TokenTickCore
import SwiftUI
import AppKit

struct SettingsView: View {
    @Environment(ApplicationModel.self) private var app
    @State private var storage: StorageSummary?
    @State private var storageError: String?
    @State private var storageRefresh = 0
    var body: some View {
        Form {
            Section("TokenTick") {
                LabeledContent("版本", value: ApplicationInfo.version)
                LabeledContent("系统要求", value: "macOS \(ApplicationInfo.minimumMacOSVersion) 或更新版本")
                LabeledContent("金额单位", value: "美元（USD）")
            }
            Section("统计") {
                Picker("时区", selection: Binding(get: { app.status?.timezone ?? TimeZone.current.identifier },
                                                set: { value in Task { await app.changeTimezone(value) } })) {
                    ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { Text($0).tag($0) }
                }
                Text("日期按所选时区统计，模型价格始终使用 UTC 日期。外观跟随系统。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("数据来源") {
                Text("Codex 目录由 CODEX_HOME 环境变量决定，未设置时使用 ~/.codex。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("应用运行时自动同步", isOn: Binding(get: { app.automaticSyncEnabled }, set: { app.automaticSyncEnabled = $0 }))
                Text("目录监听触发采集；监听正常时每 30 分钟兜底核对，失效时每分钟核对。每五分钟刷新远端数据，价格每日获取一次。")
                    .font(.caption).foregroundStyle(.secondary)
                if let issue = app.automaticSyncIssue { Text(issue).font(.caption).foregroundStyle(.secondary) }
            }
            Section("存储") {
                if let url = app.store?.databaseURL {
                    Text(url.path).font(.caption).textSelection(.enabled)
                    Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                if let storage {
                    LabeledContent("数据库及运行文件", value: ByteCountFormatter.string(fromByteCount: storage.liveBytes, countStyle: .file))
                    Text("主库 \(storage.databaseBytes.formatted()) 字节 · WAL \(storage.walBytes.formatted()) 字节 · 共享内存 \(storage.sharedMemoryBytes.formatted()) 字节")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    LabeledContent("迁移备份", value: "\(storage.backupCount) 份 · \(ByteCountFormatter.string(fromByteCount: storage.backupBytes, countStyle: .file))")
                    Text("显示文件长度，写入期间可能变化；查询不会压缩数据库或清理备份。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let storageError { Text(storageError).font(.caption).textSelection(.enabled) }
                Button("刷新存储信息") { storageRefresh += 1 }
                Button("重建统计缓存") { Task { await app.rebuild() } }.disabled(app.isSyncing || app.store == nil)
            }
            if let storage, storage.backupCount > 0 {
                Section("最近迁移备份") {
                    Text("最近 \(storage.recentBackups.count) 份。这些是旧版保留的备份；新迁移不再自动备份。")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(storage.recentBackups) { backup in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(backup.url.lastPathComponent).font(.caption).textSelection(.enabled)
                            HStack {
                                Text("\(UsageFormatting.timestamp(backup.modifiedAt?.timeIntervalSince1970)) · \(ByteCountFormatter.string(fromByteCount: backup.bytes, countStyle: .file))")
                                    .font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("显示") { NSWorkspace.shared.activateFileViewerSelecting([backup.url]) }
                                    .help(backup.url.path)
                            }
                        }
                    }
                    Button("打开全部备份") { NSWorkspace.shared.open(storage.backupDirectory) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 580, height: 640)
        .task { await app.start() }
        .task(id: "\(app.refreshID):\(storageRefresh)") {
            guard let store = app.store else { return }
            do {
                let result = try await Task.detached(priority: .utility) { try store.storageSummary() }.value
                guard !Task.isCancelled else { return }
                storage = result; storageError = nil
            } catch {
                guard !Task.isCancelled else { return }
                storageError = error.localizedDescription
            }
        }
    }
}
