import TokenTickCore
import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(ApplicationModel.self) private var app
    @State private var directory = ""
    @State private var choosingDirectory = false
    @State private var directoryError: String?
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
                TextField("Codex 目录", text: $directory)
                HStack {
                    Button("选择目录…") { choosingDirectory = true }
                    Button("保存目录") {
                        let path = (directory as NSString).expandingTildeInPath
                        var isDirectory: ObjCBool = false
                        guard !path.isEmpty, FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                              isDirectory.boolValue, FileManager.default.isReadableFile(atPath: path) else {
                            directoryError = "请选择存在且可读取的目录。"; return
                        }
                        directory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
                        app.codexDirectory = directory; directoryError = nil
                    }
                }
                if let directoryError { Text(directoryError).font(.caption).foregroundStyle(.red) }
                Toggle("应用运行时自动同步", isOn: Binding(get: { app.automaticSyncEnabled }, set: { app.automaticSyncEnabled = $0 }))
                Text("文件变化合并后采集；每分钟核对本地日志，每五分钟刷新额度和日用量。价格每日成功获取一次。休眠恢复后补扫，退出后停止。")
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
                    Text("最近 \(storage.recentBackups.count) 份。迁移前自动保存一致快照，已有备份不会自动删除。")
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
        .task { directory = app.codexDirectory; directoryError = nil; await app.start() }
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
        .fileImporter(isPresented: $choosingDirectory, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): directory = url.path; directoryError = nil
            case .failure(let error): directoryError = error.localizedDescription
            }
        }
    }
}
