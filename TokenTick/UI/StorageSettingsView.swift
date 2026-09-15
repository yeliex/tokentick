import TokenTickCore
import SwiftUI
import AppKit

struct StorageSettingsView: View {
    @Environment(ApplicationModel.self) private var app
    @State private var storage: StorageSummary?
    @State private var storageError: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("本地存储", systemImage: "internaldrive")
                    .font(.headline)
                Spacer()
                if let storage {
                    Text(ByteCountFormatter.string(fromByteCount: storage.liveBytes, countStyle: .file))
                        .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                        .accessibilityLabel("数据库大小")
                        .accessibilityValue(ByteCountFormatter.string(fromByteCount: storage.liveBytes, countStyle: .file))
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 3) {
                Text("Codex 目录").font(.subheadline).fontWeight(.medium)
                HStack(alignment: .top, spacing: 12) {
                    Text(LocalUsageScanner.defaultCodexHome.path)
                        .font(.callout).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        NSWorkspace.shared.open(LocalUsageScanner.defaultCodexHome)
                    } label: {
                        Image(systemName: "folder").frame(width: 20, height: 20)
                    }
                    .buttonStyle(.borderless)
                    .help("打开 Codex 目录")
                    .accessibilityLabel("打开 Codex 目录")
                }
            }
            if let url = app.store?.databaseURL {
                Divider()
                VStack(alignment: .leading, spacing: 3) {
                    Text("数据库").font(.subheadline).fontWeight(.medium)
                    HStack(alignment: .top, spacing: 12) {
                        Text(url.path)
                            .font(.callout).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        } label: {
                            Image(systemName: "folder").frame(width: 20, height: 20)
                        }
                        .buttonStyle(.borderless)
                        .help("打开数据库所在目录")
                        .accessibilityLabel("打开数据库所在目录")
                    }
                }
            }
            if let storageError { Text(storageError).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
        }
        .usageSurface()
        .task { await app.start() }
        .task(id: app.refreshID) {
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
