import Darwin
import Foundation
import Testing
import Synchronization
@testable import TokenTickCore

struct CodexStorageScannerTests {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ path: String, in root: URL, count: Int = 10_000) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 42, count: count).write(to: url)
        return url
    }

    @Test func enumerationFailureReportsMetadataButMissingRootIsExpected() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let diagnostics = Mutex<[SynchronizationDiagnostic]>([])
        let missing = root.appendingPathComponent("absent")
        _ = try await CodexStorageScanner.scan(root: missing, projectlessDirectory: missing,
            onDiagnostic: { diagnostic in diagnostics.withLock { $0.append(diagnostic) } })
        #expect(diagnostics.withLock { $0.isEmpty })
        let file = try write("private-file", in: root)
        _ = try await CodexStorageScanner.scan(root: file, projectlessDirectory: missing,
            onDiagnostic: { diagnostic in diagnostics.withLock { $0.append(diagnostic) } })
        #expect(diagnostics.withLock { $0.first?.operation } == "storage.enumerate")
        #expect(!diagnostics.withLock { String(describing: $0) }.contains(file.path))
    }

    @Test func classifiesSystemTotalsAndPreservesSourceFiles() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try write("sessions/2026/record.jsonl.zst", in: root)
        _ = try write("worktrees/tree/node_modules/pkg/file", in: root)
        _ = try write("log/diagnostic", in: root)
        _ = try write("plugins/cache/entry", in: root)
        _ = try write("unknown/.hidden", in: root)
        _ = try write("a file with spaces", in: root)
        let before = try Data(contentsOf: file)
        let result = try await CodexStorageScanner.scan(root: root, projectlessDirectory: root.appendingPathComponent("absent"))
        #expect(result.issueCount == 0)
        #expect(result.groups.filter { $0.category != .generatedContent && $0.category != .projectless }.allSatisfy { $0.allocatedBytes > 0 })
        #expect(result.allocatedBytes == result.groups.flatMap(\.entries).reduce(0) { $0 + $1.allocatedBytes })
        let tree = result.groups.first { $0.category == .worktrees }?.entries.first?.children.first
        #expect(tree?.url.lastPathComponent == "tree")
        #expect(tree?.allocatedBytes ?? 0 > 0)
        #expect(try Data(contentsOf: file) == before)
        #expect(result.groups.first { $0.category == .other }?.entries.count == 2)
    }

    @Test func generatedContentAndConfiguredTaskFolderAreSeparate() async throws {
        let root = try temporaryRoot()
        let tasks = try temporaryRoot()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: tasks)
        }
        _ = try write("generated_images/image.png", in: root)
        _ = try write("visualizations/chart.html", in: root)
        _ = try write("output/file", in: tasks)
        try Data("[desktop]\nprojectlessWorkspaceRoot = \"\(tasks.path)\"\n".utf8).write(to: root.appendingPathComponent("config.toml"))
        #expect(CodexStorageScanner.projectlessRoot(for: root) == tasks.resolvingSymlinksInPath())
        let result = try await CodexStorageScanner.scan(root: root)
        #expect(result.groups.first { $0.category == .generatedContent }?.entries.count == 2)
        #expect(result.groups.first { $0.category == .projectless }?.allocatedBytes ?? 0 > 0)
        #expect(result.groups.first { $0.category == .projectless }?.entries.first?.children.map(\.url.lastPathComponent) == ["output"])
        #expect(result.groups.first { $0.category == .conversations }?.allocatedBytes == 0)
        #expect(result.groups.last?.category == .other)
        #expect(result.groups.first { $0.category == .other }?.entries.map(\.url.lastPathComponent) == ["config.toml"])
        try Data("[desktop]\nprojectlessWorkspaceRoot = '~/Tasks'\n".utf8).write(to: root.appendingPathComponent("config.toml"))
        #expect(CodexStorageScanner.projectlessRoot(for: root, userHome: tasks) == tasks.appendingPathComponent("Tasks").resolvingSymlinksInPath())
        try FileManager.default.removeItem(at: root.appendingPathComponent("config.toml"))
        #expect(CodexStorageScanner.projectlessRoot(for: root, userHome: tasks) == tasks.appendingPathComponent("Documents/Codex").resolvingSymlinksInPath())
    }

    @Test func nestedTaskFolderIsNotCountedTwice() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try write("outputs/tasks/file", in: root)
        let baseline = try await CodexStorageScanner.scan(root: root, projectlessDirectory: root.appendingPathComponent("missing"))
        let result = try await CodexStorageScanner.scan(root: root, projectlessDirectory: root.appendingPathComponent("outputs/tasks"))
        #expect(result.allocatedBytes == baseline.allocatedBytes)
        #expect(result.groups.first { $0.category == .projectless }?.allocatedBytes ?? 0 > 0)
    }

    @Test func usesSystemHardLinkAndSymlinkSemantics() async throws {
        let root = try temporaryRoot()
        let outside = try temporaryRoot()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let original = try write("a", in: root)
        _ = try write("large", in: outside, count: 1_000_000)
        try FileManager.default.linkItem(at: original, to: root.appendingPathComponent("b"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("external-link"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("loop"), withDestinationURL: root)
        let result = try await CodexStorageScanner.scan(root: root, projectlessDirectory: root.appendingPathComponent("absent"))
        #expect(result.issueCount == 0)
        #expect(result.allocatedBytes > 0 && result.allocatedBytes < 30_000)
        #expect(result.groups.flatMap(\.entries).allSatisfy { $0.children.isEmpty })
    }

    @Test func rescanReflectsRemovalAndMissingRootUsesZero() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try write("record.jsonl", in: root)
        #expect(try await CodexStorageScanner.scan(root: root, projectlessDirectory: root.appendingPathComponent("absent")).allocatedBytes > 0)
        try FileManager.default.removeItem(at: file)
        let empty = try await CodexStorageScanner.scan(root: root, projectlessDirectory: root.appendingPathComponent("absent"))
        #expect(empty.allocatedBytes == 0 && empty.issueCount == 0)
        let missing = try await CodexStorageScanner.scan(root: root.appendingPathComponent("missing"), projectlessDirectory: root.appendingPathComponent("absent"))
        #expect(missing.allocatedBytes == 0)
    }

    @Test func unreadableDirectoryProducesPartialResult() async throws {
        let root = try temporaryRoot()
        let locked = root.appendingPathComponent("locked")
        defer {
            chmod(locked.path, 0o700)
            try? FileManager.default.removeItem(at: root)
        }
        _ = try write("locked/file", in: root)
        _ = try write("sessions/record", in: root)
        #expect(chmod(locked.path, 0) == 0)
        let result = try await CodexStorageScanner.scan(root: root, projectlessDirectory: root.appendingPathComponent("absent"))
        #expect(result.issueCount > 0)
        #expect(result.groups.first { $0.category == .other }?.incomplete == true)
        #expect(result.groups.first { $0.category == .conversations }?.allocatedBytes ?? 0 > 0)
    }

    @Test func cancellationDoesNotReturnPartialSuccess() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await CodexStorageScanner.scan(root: root, projectlessDirectory: root.appendingPathComponent("absent"))
        }
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
    }

    @Test func publishesChildTotalsBeforeParentCompletesAndParsesMultiplePipeReads() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<150 {
            _ = try write("worktrees/目录-\(index)-😀/file", in: root)
        }
        let progress = Mutex<[CodexStorageSnapshot]>([])
        let result = try await CodexStorageScanner.scan(root: root, projectlessDirectory: root.appendingPathComponent("absent"),
            onProgress: { snapshot in progress.withLock { $0.append(snapshot) } })
        let first = try #require(progress.withLock { $0.first })
        let parent = try #require(first.groups.first { $0.category == .worktrees }?.entries.first)
        #expect(parent.incomplete)
        #expect(!parent.children.isEmpty && parent.children.count < 150)
        #expect(parent.allocatedBytes == parent.children.reduce(0) { $0 + $1.allocatedBytes })
        #expect(first.allocatedBytes > 0 && first.allocatedBytes < result.allocatedBytes)
        let finalParent = try #require(result.groups.first { $0.category == .worktrees }?.entries.first)
        #expect(!finalParent.incomplete)
        #expect(finalParent.children.count == 150)
        #expect(finalParent.children.allSatisfy { $0.url.lastPathComponent.hasSuffix("-😀") })
        #expect(result.issueCount == 0)
    }

    @Test func cancellationAfterProgressDoesNotReturnSuccess() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try write("worktrees/tree/file", in: root)
        let progressCount = Mutex(0)
        let task = Task {
            try await CodexStorageScanner.scan(root: root, projectlessDirectory: root.appendingPathComponent("absent"),
                onProgress: { _ in
                    progressCount.withLock { $0 += 1 }
                    withUnsafeCurrentTask { $0?.cancel() }
                })
        }
        do { _ = try await task.value; Issue.record("Expected cancellation after progress") }
        catch { #expect(error is CancellationError) }
        #expect(progressCount.withLock { $0 } == 1)
    }

    @Test func largeTreeRetainsOnlyShallowDirectoryTotals() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<2000 { _ = try write("worktrees/tree/nested/file-\(index)", in: root, count: 1) }
        let result = try await CodexStorageScanner.scan(root: root, projectlessDirectory: root.appendingPathComponent("absent"))
        #expect(result.issueCount == 0)
        let entries = result.groups.first { $0.category == .worktrees }?.entries
        #expect(entries?.count == 1)
        #expect(entries?.first?.children.count == 1)
        #expect(entries?.first?.children.first?.children.isEmpty == true)
    }
}
