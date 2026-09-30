import Foundation
import Testing
@testable import TokenTickCore

struct SSHDeviceSourceTests {
    @Test func explicitHomeRelativePathUsesRemoteLoginDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let codex = root.appendingPathComponent("custom-codex")
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = try SFTPTransport(executable: URL(fileURLWithPath: "/usr/libexec/sftp-server"), arguments: ["-R", "-d", root.path])
        let source = SSHDeviceSource(home: "/~/custom-codex", client: SFTPClient(transport: transport))
        do {
            let resolved = try await source.probe()
            #expect(resolved.hasSuffix("/" + root.lastPathComponent + "/custom-codex"))
            #expect(try await source.manifest().files.isEmpty)
            await source.close()
        } catch {
            await source.close()
            throw error
        }
    }

    @Test func manifestAndRangeReadsUseSelectedRoot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessions = root.appendingPathComponent("sessions/2026/09/27")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = sessions.appendingPathComponent("rollout-2026-09-27T10-00-00-00000000-0000-0000-0000-000000000001.jsonl")
        let content = Data(repeating: 65, count: 100_000)
        try content.write(to: file)
        let transport = try SFTPTransport(executable: URL(fileURLWithPath: "/usr/libexec/sftp-server"), arguments: ["-R"])
        let source = SSHDeviceSource(home: root.path, client: SFTPClient(transport: transport))
        do {
            let manifest = try await source.manifest()
            let entry = try #require(manifest.files.first)
            #expect(manifest.files.count == 1)
            let selected = try await source.manifest(directories: ["sessions/2026/09/27", "sessions/2026/09", "sessions/missing"])
            #expect(selected.files == manifest.files)
            #expect(try await source.manifest(directories: ["sessions/missing"]).files.isEmpty)
            #expect(try await source.read(entry, offset: 80_000, count: 20_000) == content.suffix(20_000))
            try Data([1, 2]).write(to: file)
            await #expect(throws: DeviceSourceFailure.changed) { try await source.read(entry, offset: 0, count: 3) }
            await source.close()
        } catch {
            await source.close()
            throw error
        }
    }

    @Test func boundedReadCompletesWhileSourceKeepsAppending() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = sessions.appendingPathComponent("rollout-2026-09-27T10-00-00-00000000-0000-0000-0000-000000000002.jsonl")
        let content = Data(repeating: 65, count: 4 * 1_024 * 1_024)
        try content.write(to: file)
        let transport = try SFTPTransport(executable: URL(fileURLWithPath: "/usr/libexec/sftp-server"), arguments: ["-R"])
        let source = SSHDeviceSource(home: root.path, client: SFTPClient(transport: transport))
        let entry = try #require(try await source.manifest().files.first)
        let appending = Task.detached {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            var writes = 0
            while !Task.isCancelled {
                try handle.write(contentsOf: Data([66]))
                writes += 1
                do { try await Task.sleep(for: .milliseconds(1)) } catch { break }
            }
            return writes
        }
        do {
            let bytes = try await source.read(entry, offset: 0, count: content.count)
            appending.cancel()
            #expect(try await appending.value > 1)
            #expect(bytes == content)
            await source.close()
        } catch {
            appending.cancel()
            _ = try? await appending.value
            await source.close()
            throw error
        }
    }

}
