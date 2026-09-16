import AppKit
import Observation
import SwiftUI
import TokenTickCore

@MainActor @Observable
final class CodexStorageModel {
    private(set) var snapshot: CodexStorageSnapshot?
    private(set) var isScanning = false
    private(set) var root = LocalUsageScanner.defaultCodexHome
    var expanded: Set<String> = []
    var scrollID: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let cache = LocalDisplayCache()
    @ObservationIgnored private var hasEnteredPage = false

    func loadCache() async {
        guard snapshot == nil else { return }
        let cached = await cache.storage(for: root)
        if snapshot == nil { snapshot = cached }
    }

    func enterPage() {
        guard !hasEnteredPage else { return }
        hasEnteredPage = true
        scan()
    }

    func scan() {
        guard task == nil else { return }
        root = LocalUsageScanner.defaultCodexHome
        if snapshot?.root != root.standardizedFileURL.resolvingSymlinksInPath() { snapshot = nil }
        let root = root
        isScanning = true
        task = Task {
            defer { isScanning = false; task = nil }
            await loadCache()
            guard !Task.isCancelled else { return }
            let worker = Task.detached(priority: .utility) { try await CodexStorageScanner.scan(root: root) }
            do {
                let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                snapshot = result
                await cache.saveStorage(result)
            } catch {
                // Keep the last snapshot when a scan cannot complete.
            }
        }
    }

    func cancel() { task?.cancel() }
}

extension CodexStorageCategory {
    var title: String {
        switch self {
        case .conversations: String(localized: "Conversation records")
        case .worktrees: String(localized: "Worktrees")
        case .logs: String(localized: "Logs")
        case .plugins: String(localized: "Plugins and skills")
        case .generatedContent: String(localized: "Generated content")
        case .projectless: String(localized: "Projectless tasks")
        case .other: String(localized: "Other data")
        }
    }

    var color: Color {
        switch self {
        case .conversations: .blue
        case .worktrees: .orange
        case .logs: .purple
        case .plugins: .teal
        case .generatedContent: .indigo
        case .projectless: .pink
        case .other: .gray
        }
    }
}

struct CodexStorageSummaryView: View {
    @Environment(ApplicationModel.self) private var app
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(String(localized: "Storage")).font(.headline)
                Spacer()
                if app.storage.isScanning {
                    ProgressView().controlSize(.small).help(String(localized: "Scanning storage…"))
                }
                Button { app.requestedPage = .storage } label: {
                    Label(String(localized: "View details"), systemImage: "arrow.up.right")
                }.buttonStyle(.plain).font(.callout).foregroundStyle(.secondary)
            }
            StorageTotalsView(model: app.storage)
        }.usageSurface()
    }
}

private struct StorageTotalsView: View {
    let model: CodexStorageModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let snapshot = model.snapshot {
                HStack(alignment: .firstTextBaseline) {
                    Text(ByteCountFormatter.string(fromByteCount: snapshot.allocatedBytes, countStyle: .file))
                        .font(.system(size: 32, weight: .semibold)).monospacedDigit().textSelection(.enabled)
                        .help(String(localized: "Approximate disk usage reported by the system."))
                    Text(String(localized: "Codex local data")).foregroundStyle(.secondary)
                    Spacer()
                }
                if snapshot.allocatedBytes > 0 {
                    GeometryReader { geometry in
                        HStack(spacing: 0) {
                            ForEach(snapshot.groups) { group in
                                group.category.color
                                    .frame(width: geometry.size.width * Double(group.allocatedBytes) / Double(snapshot.allocatedBytes))
                            }
                        }.clipShape(Capsule())
                    }.frame(height: 12).accessibilityHidden(true)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 24) { legend(snapshot) }
                    VStack(alignment: .leading, spacing: 10) { legend(snapshot) }
                }
            } else {
                Text(ByteCountFormatter.string(fromByteCount: 0, countStyle: .file))
                    .font(.system(size: 32, weight: .semibold)).monospacedDigit()
            }
        }
    }

    @ViewBuilder private func legend(_ snapshot: CodexStorageSnapshot) -> some View {
        ForEach(snapshot.groups) { group in
            VStack(alignment: .leading, spacing: 5) {
                Label { Text(group.category.title) } icon: {
                    Circle().fill(group.category.color).frame(width: 7, height: 7)
                }.font(.caption).foregroundStyle(.secondary)
                    .help(group.category == .generatedContent ? String(localized: "Generated images and visualizations") : group.category == .projectless ? (snapshot.projectlessRoot?.path ?? group.category.title) : group.category.title)
                Text(ByteCountFormatter.string(fromByteCount: group.allocatedBytes, countStyle: .file))
                    .font(.callout.weight(.medium)).monospacedDigit()
                Text(snapshot.allocatedBytes > 0 ? (Double(group.allocatedBytes) / Double(snapshot.allocatedBytes)).formatted(.percent.precision(.fractionLength(1))) : "—")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct CodexStorageView: View {
    @Environment(ApplicationModel.self) private var app

    var body: some View {
        @Bindable var model = app.storage
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text(String(localized: "Codex local data")).font(.headline)
                        Spacer()
                    }
                    pathRow(model.snapshot?.root ?? model.root)
                    StorageTotalsView(model: model)
                }.usageSurface().id("summary")
                if let snapshot = model.snapshot {
                    ForEach(snapshot.groups.filter { $0.category == .worktrees || $0.category == .conversations || $0.category == .projectless }) { group in
                        DisclosureGroup(isExpanded: expansion(group.category.rawValue)) {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(group.category != .conversations ? group.entries.flatMap(\.children) : group.entries) { entry in
                                    entryRow(entry).padding(.vertical, 6)
                                }
                            }.padding(.leading, 20).padding(.top, 10)
                        } label: {
                            HStack {
                                Circle().fill(group.category.color).frame(width: 9, height: 9)
                                Text(group.category.title).font(.headline)
                                Spacer()
                                Text(ByteCountFormatter.string(fromByteCount: group.allocatedBytes, countStyle: .file)).monospacedDigit()
                            }
                        }.usageSurface().id(group.category.rawValue)
                    }
                }
            }.scrollTargetLayout()
                .padding(32).frame(maxWidth: 1280).frame(maxWidth: .infinity)
        }.scrollPosition(id: $model.scrollID, anchor: .top)
        .onAppear { model.enterPage() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if let snapshot = model.snapshot {
                    Text(String(localized: "Last scanned: \(snapshot.finishedAt.formatted(date: .abbreviated, time: .standard))"))
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                }
            }.sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .primaryAction) {
                Button { model.scan() } label: {
                    Group {
                        if model.isScanning { ProgressView().controlSize(.small) }
                        else { Image(systemName: "arrow.triangle.2.circlepath") }
                    }.frame(width: 16, height: 16)
                }
                .disabled(model.isScanning).keyboardShortcut("r")
                .help(model.isScanning ? String(localized: "Scanning storage…") : String(localized: "Refresh"))
                .accessibilityLabel(model.isScanning ? String(localized: "Scanning storage…") : String(localized: "Refresh"))
            }
        }
    }

    private func expansion(_ id: String) -> Binding<Bool> {
        Binding(get: { app.storage.expanded.contains(id) }, set: {
            if $0 { app.storage.expanded.insert(id) } else { app.storage.expanded.remove(id) }
        })
    }

    private func entryRow(_ entry: CodexStorageEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.isDirectory ? "folder" : "doc").frame(width: 20).foregroundStyle(.secondary)
            Text(entry.url.lastPathComponent).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                .help(entry.url.path)
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: entry.allocatedBytes, countStyle: .file))
                .monospacedDigit()
            revealButton(entry.url)
        }.contextMenu {
            Button(String(localized: "Copy path")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.url.path, forType: .string)
            }
        }
    }

    private func pathRow(_ url: URL) -> some View {
        HStack {
            Text(url.path).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            revealButton(url)
        }
    }

    private func revealButton(_ url: URL) -> some View {
        Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
            Image(systemName: "folder").frame(width: 24, height: 24)
        }.buttonStyle(.borderless)
            .help(String(localized: "Show in Finder")).accessibilityLabel(String(localized: "Show in Finder"))
    }
}
