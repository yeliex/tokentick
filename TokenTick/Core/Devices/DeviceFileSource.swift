import Foundation

/// Resolve the login belonging to this source before collecting its logs.
protocol DeviceAccountSource: Sendable {
    func account() async throws -> DeviceAccount
}

struct DeviceSourceFile: Codable, Sendable, Equatable {
    let path: String
    let size: UInt64
    let modifiedAt: Double
    let identity: String

    var rollout: RolloutIdentity? { RolloutIdentity(fileName: (path as NSString).lastPathComponent) }
}

struct DeviceSourceManifest: Codable, Sendable {
    let root: String
    let files: [DeviceSourceFile]
}

protocol DeviceFileSource: Sendable {
    func probe() async throws -> String
    func manifest() async throws -> DeviceSourceManifest
    func manifest(directories: [String]) async throws -> DeviceSourceManifest
    func read(_ file: DeviceSourceFile, offset: UInt64, count: Int) async throws -> Data
    func close() async
    func catalog(after: String?) async throws -> DeviceCatalogPage
}

extension DeviceFileSource {
    func manifest(directories: [String]) async throws -> DeviceSourceManifest { try await manifest() }
    func close() async {}
    func catalog(after: String?) async throws -> DeviceCatalogPage { throw DeviceSourceFailure.unsupported }
}

enum DeviceSourceFailure: String, Error, Codable, LocalizedError {
    case inaccessible, changed, invalidPath, invalidResponse, unsupported, authentication, hostVerification, conflictingCopies, configuration, smbDirectory

    var errorDescription: String? {
        switch self {
        case .smbDirectory: String(localized: "SMB-mounted folders are not supported. Use an SSH connection for this device.", bundle: .module)
        case .inaccessible: String(localized: "The Codex directory is unavailable. Check the connection and directory permissions.", bundle: .module)
        case .changed: String(localized: "The source file changed during reading. It will be checked again before resuming.", bundle: .module)
        case .invalidPath: String(localized: "The source path leaves the selected Codex directory.", bundle: .module)
        case .invalidResponse: String(localized: "The device returned an invalid response.", bundle: .module)
        case .unsupported: String(localized: "The device does not provide the required file access capabilities.", bundle: .module)
        case .authentication: String(localized: "The device requires authentication. Check its connection settings.", bundle: .module)
        case .hostVerification: String(localized: "Verify this SSH host in Terminal before connecting with TokenTick.", bundle: .module)
        case .conflictingCopies: String(localized: "Conflicting copies of this rollout were found. Existing usage was kept and updates to this rollout were stopped.", bundle: .module)
        case .configuration: String(localized: "The SSH configuration conflicts with the collection command. Check this host's SSH settings.", bundle: .module)
        }
    }
}

/// The same bounded worker handles local folders and mounted shares, including mounts that stop responding.
actor DirectoryDeviceSource: DeviceFileSource, DeviceTraceSource, DeviceAccountSource {
    let root: URL
    let executable: URL
    private var worker: FramedProcessConnection?

    init(root: URL, executable: URL) { self.root = root; self.executable = executable }

    func close() async {
        await worker?.close()
        worker = nil
    }

    func account() async throws -> DeviceAccount {
        guard case .account(let identity) = try await request(.account) else { throw DeviceSourceFailure.invalidResponse }
        return identity
    }

    func traceFiles() async throws -> [String] {
        guard case .traceFiles(let files) = try await request(.traceFiles) else { throw DeviceSourceFailure.invalidResponse }
        return files
    }

    func tracePage(file: String, cursor: CodexFastEvidence.Cursor?) async throws -> DeviceTracePage {
        guard case .tracePage(let page) = try await request(.tracePage(file: file, cursor: cursor)) else { throw DeviceSourceFailure.invalidResponse }
        return page
    }

    func catalog(after: String?) async throws -> DeviceCatalogPage {
        guard case .catalog(let page) = try await request(.catalog(after: after)) else { throw DeviceSourceFailure.invalidResponse }
        return page
    }

    func probe() async throws -> String {
        guard case .root(let path) = try await request(.probe) else { throw DeviceSourceFailure.invalidResponse }
        return path
    }

    func manifest() async throws -> DeviceSourceManifest {
        guard case .manifest(let manifest) = try await request(.manifest) else { throw DeviceSourceFailure.invalidResponse }
        return manifest
    }

    func manifest(directories: [String]) async throws -> DeviceSourceManifest {
        guard case .manifest(let manifest) = try await request(.selectedManifest(directories)) else { throw DeviceSourceFailure.invalidResponse }
        return manifest
    }

    func read(_ file: DeviceSourceFile, offset: UInt64, count: Int) async throws -> Data {
        guard case .bytes(let data) = try await request(.read(file, offset: offset, count: count)) else {
            throw DeviceSourceFailure.invalidResponse
        }
        return data
    }

    private func request(_ operation: DeviceWorker.Operation) async throws -> DeviceWorker.Reply {
        let input = try JSONEncoder().encode(DeviceWorker.Request(root: root.path, operation: operation))
        if worker == nil {
            worker = try FramedProcessConnection(executable: executable, arguments: ["--device-worker"], maximumLength: 32 * 1_024 * 1_024)
        }
        guard let worker else { throw DeviceSourceFailure.inaccessible }
        let output = try await worker.exchange(input)
        guard let reply = try? JSONDecoder().decode(DeviceWorker.Reply.self, from: output) else {
            throw DeviceSourceFailure.invalidResponse
        }
        if case .failure(let failure) = reply { throw failure }
        return reply
    }
}
