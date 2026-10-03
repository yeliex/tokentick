import Foundation

/// System OpenSSH owns host verification, ssh_config, agent selection, and key authentication.
actor SSHDeviceSource: DeviceFileSource, DeviceAccountSource, DeviceTraceSource {
    private let arguments: [String]
    private let environment: [String: String]
    private let home: String
    private var client: SFTPClient?
    private var root: String?
    private var metadata: SSHMetadataQuery?
    private var closed = false
    private var catalogDesktopLoaded = false
    private var catalogDesktop: DesktopProjectCatalog?

    init(device: RemoteDevice, executable: URL, configurationDirectory: URL, sshConfiguration: URL? = nil) async throws {
        guard case .ssh(let host, let user, let port, let home) = device.connection else {
            throw DeviceConfigurationError.invalidConfiguration
        }
        self.home = home ?? ""
        let hasPassword = try device.address.map { try ParsedDeviceConnection(address: $0).password != nil } ?? false
        var arguments: [String] = sshConfiguration.map { ["-F", $0.path] } ?? []
        if let user { arguments += ["-l", user] }
        if let port { arguments += ["-p", String(port)] }
        if hasPassword {
            arguments += ["-o", "PreferredAuthentications=password,keyboard-interactive,gssapi-with-mic,hostbased,publickey"]
        }
        arguments += ["--", host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host]
        self.arguments = arguments
        var environment = try await LoginShellEnvironment.shared.values()
        if hasPassword {
            environment["SSH_ASKPASS"] = executable.path
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment["TOKENTICK_DEVICE_ASKPASS"] = "1"
            environment["DISPLAY"] = "tokentick"
            environment["TOKENTICK_DEVICE_ID"] = device.id
            environment["TOKENTICK_DEVICE_CONFIGURATION_DIRECTORY"] = configurationDirectory.path
        }
        self.environment = environment
    }

    init(home: String, client: SFTPClient, metadata: SSHMetadataQuery? = nil) {
        self.home = home
        self.client = client
        self.metadata = metadata
        arguments = []
        environment = [:]
    }

    private func query() async throws -> SSHMetadataQuery {
        guard !closed else { throw DeviceSourceFailure.inaccessible }
        if let metadata { return metadata }
        let client = try connection()
        let login = try await client.realpath(".")
        let windows = login.range(of: #"^/[A-Za-z]:/"#, options: .regularExpression) != nil
        let runtime = login + "/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/" + (windows ? "node.exe" : "node")
        guard try await client.stat(runtime).isRegularFile else { throw DeviceSourceFailure.unsupported }
        let shell: SSHMetadataQuery.Shell
        if windows {
            // Query the configured native launcher; do not replace the user's shell or SSH settings.
            let registry = try await DeviceCommand.run(executable: URL(fileURLWithPath: "/usr/bin/ssh"),
                arguments: arguments + [#"reg.exe query HKLM\SOFTWARE\OpenSSH"#],
                environment: environment, timeout: 30, outputLimit: 16_384)
            let value = String(decoding: registry.output, as: UTF8.self).lowercased()
                .split(whereSeparator: \.isNewline)
                .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("defaultshell ") }
            if registry.status == 0 && (value?.contains("powershell.exe") == true || value?.contains("pwsh.exe") == true) {
                shell = .powershell
            } else if registry.status == 0 && (value == nil || value?.contains("cmd.exe") == true) {
                shell = .commandPrompt
            } else {
                // Do not guess after a failed registry read or for an unrecognized configured shell.
                throw DeviceSourceFailure.unsupported
            }
        } else { shell = .posix }
        let command = try SSHMetadataQuery.command(path: windows ? String(runtime.dropFirst()) : runtime, shell: shell)
        let result = SSHMetadataQuery(arguments: arguments, environment: environment, command: command)
        metadata = result
        return result
    }

    private func databaseRoot() async throws -> String {
        let path = try await probe()
        return path.range(of: #"^/[A-Za-z]:/"#, options: .regularExpression) == nil ? path : String(path.dropFirst())
    }

    func catalog(after: String?) async throws -> DeviceCatalogPage {
        let request = SSHMetadataQuery.Request(operation: "catalog", root: try await databaseRoot(),
            after: after, includeDesktop: !catalogDesktopLoaded)
        let page = try await query().read(request, as: DeviceCatalogPage.self)
        if !catalogDesktopLoaded { catalogDesktop = page.desktop; catalogDesktopLoaded = true }
        return DeviceCatalogPage(entries: page.entries, desktop: catalogDesktop, next: page.next, available: page.available)
    }

    func traceFiles() async throws -> [String] {
        let request = SSHMetadataQuery.Request(operation: "traceFiles", root: try await databaseRoot())
        return try await query().read(request, as: [String].self)
    }

    func tracePage(file: String, cursor: CodexFastEvidence.Cursor?) async throws -> DeviceTracePage {
        let request = SSHMetadataQuery.Request(operation: "tracePage", root: try await databaseRoot(),
            file: file, cursor: cursor.map(SSHMetadataQuery.Request.Cursor.init))
        return try await query().read(request, as: DeviceTracePage.self)
    }

    func account() async throws -> DeviceAccount {
        let root = try await databaseRoot()
        let query = try await query()
        let task = Task.detached(priority: .utility) {
            let session = try query.accountSession(root: root)
            defer { session.close() }
            return try DeviceAccount.read(session: session)
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    func close() async {
        closed = true
        await client?.close()
        client = nil
    }

    private func connection() throws -> SFTPClient {
        guard !closed else { throw DeviceSourceFailure.inaccessible }
        if let client { return client }
        let transport = try SFTPTransport(arguments: ["-s"] + arguments + ["sftp"], environment: environment)
        let result = SFTPClient(transport: transport)
        client = result
        return result
    }

    func probe() async throws -> String {
        if let root { return root }
        let client = try connection()
        var requested = home
        if requested.isEmpty {
            requested = try await query().read(.init(operation: "root", root: nil), as: String.self)
        }
        if requested.hasPrefix("/~/") || requested.hasPrefix("~/") {
            let relative = requested.hasPrefix("/~/") ? String(requested.dropFirst(3)) : String(requested.dropFirst(2))
            requested = try await client.realpath(".") + "/" + relative
        }
        // URL paths may contain a Windows drive path encoded with backslash separators.
        let drive = requested.hasPrefix("/") ? String(requested.dropFirst()) : requested
        if drive.count >= 3, drive[drive.index(after: drive.startIndex)] == ":",
           drive.first?.isASCII == true, drive.first?.isLetter == true {
            requested = "/" + drive.replacingOccurrences(of: "\\", with: "/")
        }
        let path = try await client.realpath(requested)
        guard try await client.stat(path).isDirectory else { throw DeviceSourceFailure.inaccessible }
        root = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        return root!
    }

    private func resolved(_ relative: String) async throws -> String {
        guard !relative.isEmpty, !relative.contains("\\"),
              !relative.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw DeviceSourceFailure.invalidPath
        }
        let root = try await probe()
        let client = try connection()
        let path = try await client.realpath(root + "/" + relative)
        guard path.hasPrefix(root == "/" ? "/" : root + "/") else { throw DeviceSourceFailure.invalidPath }
        return path
    }

    func manifest() async throws -> DeviceSourceManifest {
        try await manifest(selected: nil)
    }

    func manifest(directories: [String]) async throws -> DeviceSourceManifest {
        try await manifest(selected: directories)
    }

    private func manifest(selected: [String]?) async throws -> DeviceSourceManifest {
        let root = try await probe()
        let client = try connection()
        var pending: [String] = []
        if let selected { pending = selected }
        else {
            let rootHandle = try await client.open(root, directory: true)
            do {
                while let entries = try await client.entries(rootHandle) {
                    pending += entries.filter { ["sessions", "archived_sessions"].contains($0.name) && $0.attributes.isDirectory }.map(\.name)
                }
                try await client.closeHandle(rootHandle)
            } catch {
                try? await client.closeHandle(rootHandle)
                throw error
            }
        }
        var files: [DeviceSourceFile] = []
        var visited = Set<String>()
        while let relative = pending.popLast() {
            try Task.checkCancellation()
            let path: String
            do { path = try await resolved(relative) }
            catch let status as SFTPClient.Status where status.code == 2 { continue }
            guard visited.insert(path).inserted else { continue }
            guard visited.count <= 200_000 else { throw DeviceSourceFailure.unsupported }
            let handle: Data
            do {
                guard try await client.stat(path).isDirectory else { throw DeviceSourceFailure.inaccessible }
                handle = try await client.open(path, directory: true)
            }
            catch let status as SFTPClient.Status where status.code == 2 { continue }
            do {
                while let entries = try await client.entries(handle) {
                    for entry in entries {
                        if entry.name.hasPrefix(".") { continue }
                        guard !entry.name.contains("/"), !entry.name.contains("\\"), !entry.name.isEmpty else {
                            throw DeviceSourceFailure.invalidPath
                        }
                        let child = relative + "/" + entry.name
                        if entry.attributes.isDirectory { pending.append(child) }
                        else if entry.attributes.isRegularFile, RolloutIdentity(fileName: entry.name) != nil {
                            guard let size = entry.attributes.size, let modified = entry.attributes.modifiedAt else {
                                throw DeviceSourceFailure.unsupported
                            }
                            files.append(DeviceSourceFile(path: child, size: size, modifiedAt: Double(modified), identity: "sftp:" + child))
                        }
                        guard pending.count + visited.count + files.count <= 200_000 else { throw DeviceSourceFailure.unsupported }
                    }
                }
                try await client.closeHandle(handle)
            } catch {
                try? await client.closeHandle(handle)
                throw error
            }
        }
        return DeviceSourceManifest(root: root, files: files.sorted { $0.path > $1.path })
    }

    func read(_ file: DeviceSourceFile, offset: UInt64, count: Int) async throws -> Data {
        guard count > 0, count <= 4 * 1_024 * 1_024, offset <= file.size,
              UInt64(count) <= file.size - offset else { throw DeviceSourceFailure.invalidResponse }
        let path = try await resolved(file.path)
        let client = try connection()
        let before = try await client.stat(path)
        guard before.isRegularFile, let size = before.size, size >= file.size,
              let modifiedAt = before.modifiedAt, Double(modifiedAt) >= file.modifiedAt,
              size > file.size || Double(modifiedAt) == file.modifiedAt else { throw DeviceSourceFailure.changed }
        let handle = try await client.open(path)
        do {
            let opened = try await client.attributes(handle)
            guard opened.permitsAppend(from: before) else {
                throw DeviceSourceFailure.changed
            }
            var result = Data()
            while result.count < count {
                let bytes = try await client.read(handle, offset: offset + UInt64(result.count),
                                                  count: UInt32(min(131_072, count - result.count)))
                guard !bytes.isEmpty else { throw DeviceSourceFailure.changed }
                result.append(bytes)
            }
            let after = try await client.attributes(handle)
            let current = try await client.stat(path)
            // Appends can occur between FSTAT and STAT too. Equality here starves active logs.
            guard after.permitsAppend(from: opened), current.permitsAppend(from: after) else {
                throw DeviceSourceFailure.changed
            }
            try await client.closeHandle(handle)
            return result
        } catch {
            try? await client.closeHandle(handle)
            throw error
        }
    }
}
