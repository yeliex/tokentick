import SwiftUI
import UniformTypeIdentifiers
import TokenTickCore

struct RemoteDevicesSettingsView: View {
    @Environment(ApplicationModel.self) private var app
    let model: RemoteDevicesModel
    @State private var editing: RemoteDevice?
    @State private var editorPresented = false
    @State private var removing: RemoteDevice?
    @State private var deleteUsage = false
    @State private var actionError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(String(localized: "Remote Devices")).font(.title2.weight(.semibold))
                    Spacer()
                    Button(String(localized: "Add Device"), systemImage: "plus") {
                        editing = nil; editorPresented = true
                    }
                }
                if let error = model.error ?? actionError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                if model.configuration.devices.isEmpty {
                    ContentUnavailableView(String(localized: "No remote devices"), systemImage: "desktopcomputer")
                        .frame(maxWidth: .infinity)
                }
                ForEach(model.configuration.devices) { device in
                    card(device)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
        }
        .sheet(isPresented: $editorPresented) { RemoteDeviceEditor(model: model, existing: editing) }
        .sheet(item: $removing) { device in
            VStack(alignment: .leading, spacing: 18) {
                Text(String(localized: "Remove Device")).font(.title2.weight(.semibold))
                Text(device.name).font(.headline)
                Text(String(localized: "Remove this connection? Collected usage will be kept unless you choose to delete it."))
                Toggle(String(localized: "Delete collected usage from this device"), isOn: $deleteUsage)
                HStack {
                    Spacer()
                    Button(String(localized: "Cancel")) { removing = nil }.keyboardShortcut(.cancelAction)
                    Button(String(localized: "Remove"), role: .destructive) {
                        Task {
                            do { try await app.removeDevice(device, deleteUsage: deleteUsage); removing = nil }
                            catch { actionError = error.localizedDescription; removing = nil }
                        }
                    }
                }
            }.padding(24).frame(width: 430)
        }
    }

    private func card(_ device: RemoteDevice) -> some View {
        let status = model.statuses[device.id]
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Image(systemName: device.connection.kind == "directory" ? "folder" : "desktopcomputer").font(.title2).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(device.name).font(.headline).textSelection(.enabled)
                    Text(device.connection.displayAddress).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2).help(device.connection.displayAddress).textSelection(.enabled)
                }
                Spacer()
                if status?.busy == true { ProgressView().controlSize(.small) }
                Text(device.connection.kind == "directory" ? String(localized: "Folder") : "SSH")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let progress = status?.progress, status?.busy == true {
                ProgressView(value: Double(progress.completedFiles), total: Double(max(1, progress.totalFiles)))
                Text(String(localized: "Syncing…")).font(.caption)
            } else if let error = status?.error {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            } else {
                Text(statusText(device, status)).font(.callout).foregroundStyle(.secondary)
            }
            if let error = status?.connectionTestError {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            } else if status?.connectionTest != nil {
                Text(String(localized: "Connection available")).font(.callout).foregroundStyle(.secondary)
            }
            if let date = model.collectionDates[device.id], status?.result != nil || !device.enabled {
                LabeledContent(String(localized: "Last sync"), value: date.formatted(date: .abbreviated, time: .standard))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if status?.connectionTest != nil || status?.result != nil {
                Text(status?.connectionTest?.accountEmail ?? status?.result?.accountEmail ?? String(localized: "Unknown account"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if status?.busy != true, let issues = status?.result?.scan?.issues {
                ForEach(Array(issues.prefix(3).enumerated()), id: \.offset) { _, issue in
                    Text(issue.message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
            }
            Divider()
            HStack {
                Button(String(localized: "Test Connection")) { model.test(device) }.disabled(status?.busy == true)
                Button(String(localized: "Sync Now")) { model.run(device) }.disabled(status?.busy == true)
                if status?.busy == true {
                    Button(String(localized: "Cancel")) { Task { await model.cancel(device.id) } }
                }
                Spacer()
                Menu {
                    Button(device.enabled ? String(localized: "Pause") : String(localized: "Resume")) {
                        Task {
                            var changed = device; changed.enabled.toggle()
                            do { try await model.save(changed, adding: false) }
                            catch { actionError = error.localizedDescription }
                        }
                    }
                    Button(String(localized: "Edit…")) { editing = device; editorPresented = true }
                    Divider()
                    Button(String(localized: "Remove…"), role: .destructive) { deleteUsage = false; removing = device }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel(String(localized: "Device actions"))
            }.controlSize(.small)
        }
        .padding(16)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.08)))
    }

    private func statusText(_ device: RemoteDevice, _ status: RemoteDevicesModel.Status?) -> String {
        if status?.busy == true { return status?.testing == true ? String(localized: "Testing connection…") : String(localized: "Syncing…") }
        if !device.enabled { return String(localized: "Paused") }
        guard let result = status?.result else {
            if let date = model.collectionDates[device.id] {
                return String(localized: "Last updated: \(date.formatted(date: .abbreviated, time: .standard))")
            }
            return String(localized: "Not synced yet")
        }
        guard let scan = result.scan else { return String(localized: "Connection available") }
        if scan.issueCount > 0 { return String(localized: "Partially synced") }
        if scan.pendingFiles > 0 || scan.pendingMetadata { return String(localized: "Importing history…") }
        return scan.discoveredFiles == 0 ? String(localized: "No logs found") : String(localized: "Up to date")
    }
}

private struct RemoteDeviceEditor: View {
    let model: RemoteDevicesModel
    let existing: RemoteDevice?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var directory: URL?
    @State private var bookmark: Data?
    @State private var picker = false
    @State private var testing = false
    @State private var connectionAvailable = false
    @State private var saving = false
    @State private var saveTask: Task<Void, Never>?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(existing == nil ? String(localized: "Add Device") : String(localized: "Edit Device")).font(.title2.weight(.semibold))
            Form {
                Section {
                    TextField(String(localized: "Name"), text: $name)
                    TextField(String(localized: "Address"), text: $address)
                        .autocorrectionDisabled()
                    if let parsed = try? ParsedDeviceConnection(address: address) {
                        if let duplicate = model.configuration.devices.first(where: {
                            $0.id != existing?.id && $0.connection.displayAddress == parsed.connection.displayAddress
                        }) {
                            Text(String(localized: "This address is already configured as \(duplicate.name). You can use the existing device."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Button(String(localized: "Use Local Folder")) { picker = true }
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(localized: "Enter an SSH URL or choose the Codex folder."))
                        Text(verbatim: "ssh://my-server\nssh://user@host/absolute/path/.codex\nssh://user@windows-pc/C:/Users/username/.codex\n/Volumes/Remote/codex")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }.font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
                .disabled(saving || testing)
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Button(testing ? String(localized: "Testing connection…") : String(localized: "Test Connection")) { test() }
                    .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving || testing)
                if connectionAvailable {
                    Text(String(localized: "Connection available")).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button(String(localized: "Cancel")) { saveTask?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Button(String(localized: "Save")) { save() }.keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving || testing)
            }
        }.padding(24).frame(width: 500)
        .fileImporter(isPresented: $picker, allowedContentTypes: [.folder]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                directory = url
                address = url.path
            } catch { self.error = error.localizedDescription }
        }
        .onChange(of: address) { connectionAvailable = false; error = nil }
        .onDisappear { saveTask?.cancel() }
        .onAppear {
            guard let existing else { return }
            name = existing.name
            address = existing.address ?? existing.connection.displayAddress
            if case .directory(let path, let saved) = existing.connection {
                directory = URL(fileURLWithPath: path)
                bookmark = saved
            }
        }
    }

    private func draftDevice() throws -> RemoteDevice {
        let parsed = try ParsedDeviceConnection(address: address)
        let connection: DeviceConnection
        if case .directory(let path, _) = parsed.connection {
            connection = .directory(path: path, bookmark: directory?.path == path ? bookmark : nil)
        } else { connection = parsed.connection }
        var device = existing ?? RemoteDevice(name: name, connection: connection)
        device.edit(name: name.trimmingCharacters(in: .whitespacesAndNewlines), connection: connection, enabled: device.enabled)
        device.address = address
        return device
    }

    private func test() {
        do {
            let device = try draftDevice()
            testing = true; connectionAvailable = false; error = nil
            saveTask = Task {
                defer { testing = false; saveTask = nil }
                do {
                    _ = try await model.testDraft(device)
                    try Task.checkCancellation()
                    connectionAvailable = true
                } catch is CancellationError { }
                catch { self.error = error.localizedDescription }
            }
        } catch { self.error = error.localizedDescription }
    }

    private func save() {
        do {
            let device = try draftDevice()
            error = nil
            saving = true
            saveTask = Task {
                defer { saving = false; saveTask = nil }
                do { try await model.save(device, adding: existing == nil); dismiss() }
                catch is CancellationError { }
                catch { self.error = error.localizedDescription }
            }
        } catch { self.error = error.localizedDescription }
    }
}
