import Foundation
import Testing
@testable import TokenTickCore

struct DeviceWorkerTests {
    @Test func selectedManifestHandlesMissingAndOverlappingDirectories() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recent = root.appendingPathComponent("sessions/2026/09/27")
        let archived = root.appendingPathComponent("archived_sessions")
        try FileManager.default.createDirectory(at: recent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        let name = "rollout-2026-09-27T10-00-00-00000000-0000-0000-0000-000000000001.jsonl"
        try Data().write(to: recent.appendingPathComponent(name))
        try Data().write(to: archived.appendingPathComponent(name))
        guard case .manifest(let selected) = try DeviceWorker.execute(.init(root: root.path,
            operation: .selectedManifest(["sessions/2026/09/27", "sessions/2026/09", "sessions/missing"]))) else {
            Issue.record("Expected selected manifest"); return
        }
        #expect(selected.files.count == 1 && selected.files[0].path.hasPrefix("sessions/"))
        guard case .manifest(let full) = try DeviceWorker.execute(.init(root: root.path, operation: .manifest)) else {
            Issue.record("Expected full manifest"); return
        }
        #expect(full.files.count == 2)
    }

    @Test func mountedSMBIsRejectedBeforeAnyOperation() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = DeviceSourceFile(path: "sessions/fixture.jsonl", size: 1, modifiedAt: 0, identity: "fixture")
        let operations: [DeviceWorker.Operation] = [.probe, .manifest, .account, .catalog(after: nil),
            .traceFiles, .tracePage(file: "logs_2.sqlite", cursor: nil), .read(file, offset: 0, count: 1)]
        for operation in operations {
            #expect(throws: DeviceSourceFailure.smbDirectory) {
                try DeviceWorker.execute(.init(root: root.path, operation: operation), fileSystem: { _ in "smbfs" })
            }
        }
    }

    @Test func mountDetectionUsesLongestCompletePathAndIgnoresLetterCase() throws {
        let mounts = [(path: "/", type: "apfs"), (path: "/Volumes/Shared", type: "smbfs"),
                      (path: "/Volumes/Shared/Local", type: "apfs")]
        #expect(try DeviceWorker.mountedFileSystem(path: "/volumes/shared/codex", mounts: mounts) == "smbfs")
        #expect(try DeviceWorker.mountedFileSystem(path: "/Volumes/Shared", mounts: mounts) == "smbfs")
        #expect(try DeviceWorker.mountedFileSystem(path: "/Volumes/SharedOther", mounts: mounts) == "apfs")
        #expect(try DeviceWorker.mountedFileSystem(path: "/Volumes/Shared/Local/data", mounts: mounts) == "apfs")
        #expect(try DeviceWorker.mountedFileSystem(path: "/Volumes/Shared/local/data", mounts: mounts) == "smbfs")
        #expect(throws: DeviceSourceFailure.inaccessible) {
            try DeviceWorker.mountedFileSystem(path: "/Volumes/Shared", mounts: [])
        }
    }

    @Test func selectedDirectoryIsExactAndDoesNotRequireCodexStructure() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        guard case .root(let path) = try DeviceWorker.execute(.init(root: root.path, operation: .probe)) else {
            Issue.record("Expected selected root"); return
        }
        #expect(path == root.resolvingSymlinksInPath().path)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".codex/sessions"), withIntermediateDirectories: true)
        try Data("hidden log".utf8).write(to: root.appendingPathComponent(".codex/sessions/" + name))
        #expect(try manifest(root).files.isEmpty)
    }

    @Test func rangeReadsAllowAppendButRejectReplacementAndTraversal() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        let url = root.appendingPathComponent("sessions/" + name)
        try Data("first\n".utf8).write(to: url)
        let file = try #require(manifest(root).files.first)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("second\n".utf8))
        try handle.close()
        guard case .bytes(let bytes) = try DeviceWorker.execute(.init(root: root.path, operation: .read(file, offset: 0, count: 6))) else {
            Issue.record("Expected bounded bytes"); return
        }
        #expect(bytes == Data("first\n".utf8))
        try Data("replacement\n".utf8).write(to: url, options: .atomic)
        #expect(throws: DeviceSourceFailure.changed) {
            _ = try DeviceWorker.execute(.init(root: root.path, operation: .read(file, offset: 0, count: 6)))
        }
        let outside = DeviceSourceFile(path: "../outside", size: 1, modifiedAt: 0, identity: "unknown")
        #expect(throws: DeviceSourceFailure.invalidPath) {
            _ = try DeviceWorker.execute(.init(root: root.path, operation: .read(outside, offset: 0, count: 1)))
        }
    }

    @Test func doesNotFollowEscapingOrCyclicLinks() throws {
        let root = try temporaryDirectory(), outside = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: outside.appendingPathComponent(name))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("sessions/" + name), withDestinationURL: outside.appendingPathComponent(name))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("sessions/loop"), withDestinationURL: root)
        #expect(try manifest(root).files.isEmpty)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("archived_sessions"), withDestinationURL: outside)
        #expect(throws: DeviceSourceFailure.invalidPath) { _ = try manifest(root) }
    }

    private let name = "rollout-2026-09-09T00-00-00-00000000-0000-0000-0000-000000000001.jsonl"
    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func manifest(_ root: URL) throws -> DeviceSourceManifest {
        guard case .manifest(let manifest) = try DeviceWorker.execute(.init(root: root.path, operation: .manifest)) else {
            throw DeviceSourceFailure.invalidResponse
        }
        return manifest
    }
}
