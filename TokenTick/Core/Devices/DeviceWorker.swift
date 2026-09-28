import Foundation
import Darwin

/// Private executable entry point; no application model, telemetry, database, or login is initialized here.
public enum DeviceWorker {
    enum Operation: Codable, Sendable {
        case probe, manifest, account
        case selectedManifest([String])
        case traceFiles
        case tracePage(file: String, cursor: CodexFastEvidence.Cursor?)
        case catalog(after: String?)
        case read(DeviceSourceFile, offset: UInt64, count: Int)
    }

    struct Request: Codable, Sendable {
        let root: String
        let operation: Operation
    }

    enum Reply: Codable, Sendable {
        case root(String), manifest(DeviceSourceManifest), bytes(Data), failure(DeviceSourceFailure), catalog(DeviceCatalogPage)
        case accountEmail(String?)
        case traceFiles([String]), tracePage(DeviceTracePage)
    }

    public static func runIfRequested() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        let explicitAskpass = CommandLine.arguments.dropFirst().first == "--device-askpass"
        if explicitAskpass || environment["TOKENTICK_DEVICE_ASKPASS"] == "1" {
            let prompt = CommandLine.arguments.dropFirst(explicitAskpass ? 2 : 1).joined(separator: " ").lowercased()
            if prompt.contains("password"), !prompt.contains("yes/no"),
               let id = environment["TOKENTICK_DEVICE_ID"], UUID(uuidString: id) != nil,
               let directory = environment["TOKENTICK_DEVICE_CONFIGURATION_DIRECTORY"],
               let configuration = try? DeviceConfigurationStore(directory: URL(fileURLWithPath: directory)).load(),
               let address = configuration.devices.first(where: { $0.id == id })?.address,
               let password = try? ParsedDeviceConnection(address: address).password {
                try? FileHandle.standardOutput.write(contentsOf: Data((password + "\n").utf8))
            }
            return true
        }
        guard CommandLine.arguments.dropFirst().first == "--device-worker" else { return false }
        var selectedRoot: (path: String, url: URL)?
        var catalogReader: DeviceCatalogPage.Reader?
        while true {
            do {
                guard let header = try readInput(count: 4) else { return true }
                let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                guard length > 0, length <= 64 * 1_024,
                      let data = try readInput(count: Int(length)) else { return true }
                let reply: Reply
                do {
                    let request = try JSONDecoder().decode(Request.self, from: data)
                    if selectedRoot?.path != request.root {
                        selectedRoot = (request.root, try validatedRoot(request.root))
                        catalogReader = nil
                    }
                    if case .catalog(let after) = request.operation {
                        if catalogReader == nil { catalogReader = try DeviceCatalogPage.Reader(root: selectedRoot!.url) }
                        reply = .catalog(try catalogReader!.read(after: after))
                    } else { reply = try execute(request.operation, root: selectedRoot!.url) }
                } catch let error as DeviceSourceFailure { reply = .failure(error) }
                catch { reply = .failure(.inaccessible) }
                let output = try JSONEncoder().encode(reply)
                guard output.count <= 32 * 1_024 * 1_024 else { return true }
                let size = UInt32(output.count)
                let frame = Data(stride(from: 24, through: 0, by: -8).map { UInt8(truncatingIfNeeded: size >> $0) }) + output
                try FileHandle.standardOutput.write(contentsOf: frame)
            } catch { return true }
        }
    }

    private static func readInput(count: Int) throws -> Data? {
        var data = Data()
        while data.count < count {
            guard let bytes = try FileHandle.standardInput.read(upToCount: count - data.count), !bytes.isEmpty else { return nil }
            data.append(bytes)
        }
        return data
    }

    static func execute(_ request: Request, fileSystem: (URL) throws -> String = fileSystemName) throws -> Reply {
        try execute(request.operation, root: validatedRoot(request.root, fileSystem: fileSystem))
    }

    static func validatedRoot(_ path: String, fileSystem: (URL) throws -> String = fileSystemName) throws -> URL {
        guard path.hasPrefix("/"), !path.contains("\0") else { throw DeviceSourceFailure.invalidPath }
        let root = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        guard try fileSystem(root) != "smbfs" else { throw DeviceSourceFailure.smbDirectory }
        guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw DeviceSourceFailure.inaccessible }
        return root
    }

    static func execute(_ operation: Operation, root: URL) throws -> Reply {
        switch operation {
        case .traceFiles: return .traceFiles(try DeviceTracePage.files(root: root))
        case .tracePage(let file, let cursor): return .tracePage(try DeviceTracePage.read(root: root, file: file, previous: cursor))
        case .account: return .accountEmail(try? DeviceAccountIdentity.read(root: root))
        case .catalog(let after): return .catalog(try DeviceCatalogPage.read(root: root, after: after))
        case .probe:
            // Test access to exactly the selected directory, without requiring a Codex layout.
            _ = try FileManager.default.contentsOfDirectory(atPath: root.path)
            return .root(root.path)
        case .manifest, .selectedManifest:
            var files: [DeviceSourceFile] = []
            var failure: (any Error)?
            let folders: [String]
            if case .selectedManifest(let selected) = operation { folders = selected }
            else { folders = ["sessions", "archived_sessions"] }
            var visited = Set<String>()
            for folder in folders {
                let directory = try contained(folder, root: root)
                guard FileManager.default.fileExists(atPath: directory.path) else { continue }
                guard let enumerator = FileManager.default.enumerator(at: directory,
                    includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles], errorHandler: { _, error in failure = error; return false }) else {
                    throw DeviceSourceFailure.inaccessible
                }
                for case let url as URL in enumerator {
                    let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    if properties.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                    guard properties.isRegularFile == true, RolloutIdentity(fileName: url.lastPathComponent) != nil else { continue }
                    let path = url.resolvingSymlinksInPath().standardizedFileURL.path
                    guard path.hasPrefix(root.path + "/") else { throw DeviceSourceFailure.invalidPath }
                    let relative = String(path.dropFirst(root.path.count + 1))
                    guard visited.insert(relative).inserted else { continue }
                    files.append(try describe(try contained(relative, root: root), path: relative))
                    guard files.count <= 200_000 else { throw DeviceSourceFailure.unsupported }
                }
                if failure != nil { throw DeviceSourceFailure.inaccessible }
            }
            return .manifest(DeviceSourceManifest(root: root.path, files: files.sorted { $0.path > $1.path }))
        case .read(let file, let offset, let count):
            guard count > 0, count <= 4 * 1_024 * 1_024, offset <= file.size,
                  UInt64(count) <= file.size - offset else { throw DeviceSourceFailure.invalidResponse }
            let url = try contained(file.path, root: root)
            let before = try describe(url, path: file.path)
            guard before.identity == file.identity, before.size >= file.size,
                  before.size > file.size || before.modifiedAt == file.modifiedAt else { throw DeviceSourceFailure.changed }
            let handle = try LocalRolloutFile(url: url)
            try handle.seek(to: offset)
            let data = try handle.read(upToCount: count)
            let after = try describe(url, path: file.path)
            guard data.count == count, after.identity == before.identity, after.size >= before.size,
                  after.size > before.size || after.modifiedAt == before.modifiedAt else { throw DeviceSourceFailure.changed }
            return .bytes(data)
        }
    }

    private static func fileSystemName(_ url: URL) throws -> String {
        // Opening a network directory can block or request privacy access before rejection.
        // MNT_NOWAIT reads the kernel mount table without contacting the server.
        var entries: UnsafeMutablePointer<statfs>?
        let count = getmntinfo_r_np(&entries, MNT_NOWAIT)
        guard count > 0, let entries else { throw DeviceSourceFailure.inaccessible }
        defer { free(entries) }
        let mounts = (0..<Int(count)).map { index -> (path: String, type: String) in
            let entry = entries[index]
            let path = withUnsafeBytes(of: entry.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let type = withUnsafeBytes(of: entry.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            return (path, type)
        }
        return try mountedFileSystem(path: url.path, mounts: mounts)
    }

    static func mountedFileSystem(path: String, mounts: [(path: String, type: String)]) throws -> String {
        let match = mounts.filter { mount in
            mount.path == "/" || path == mount.path || path.hasPrefix(mount.path + "/")
        }.max { $0.path.count < $1.path.count }
        guard let match else { throw DeviceSourceFailure.inaccessible }
        // Case variants must not hide an SMB mount behind the local root. Only an exact
        // deeper mount can establish an exception on a case-sensitive filesystem.
        let folded = path.lowercased()
        if mounts.contains(where: { mount in
            let root = mount.path.lowercased()
            return mount.type == "smbfs" && mount.path.count > match.path.count
                && (folded == root || folded.hasPrefix(root + "/"))
        }) { return "smbfs" }
        return match.type
    }

    private static func contained(_ path: String, root: URL) throws -> URL {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.hasPrefix("/"), !components.contains(".."), !components.contains("."),
              !components.contains(""), !path.contains("\0") else { throw DeviceSourceFailure.invalidPath }
        let resolved = root.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(root.path == "/" ? "/" : root.path + "/") else { throw DeviceSourceFailure.invalidPath }
        return resolved
    }

    private static func describe(_ url: URL, path: String) throws -> DeviceSourceFile {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, let modified = attributes[.modificationDate] as? Date,
              let inode = attributes[.systemFileNumber] as? NSNumber, let device = attributes[.systemNumber] as? NSNumber else {
            throw DeviceSourceFailure.inaccessible
        }
        return DeviceSourceFile(path: path, size: size.uint64Value, modifiedAt: modified.timeIntervalSince1970,
                                identity: "\(device.uint64Value):\(inode.uint64Value)")
    }
}
