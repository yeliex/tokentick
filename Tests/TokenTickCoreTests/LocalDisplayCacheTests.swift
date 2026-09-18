import Foundation
import Testing
import Synchronization
@testable import TokenTickCore

struct LocalDisplayCacheTests {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func snapshot(time: Double = 1000) -> CurrentLimitSnapshot {
        var value = CurrentLimitSnapshot(accountID: "account-a", observedAt: time, source: "api", scopeKey: "account:account-a",
            windows: [.init(limitID: "codex", kind: "primary", usedPercent: 42, durationMinutes: 300, resetsAt: 20_000)],
            sourceJSON: "raw-response-must-not-be-cached")
        value.planType = "pro"
        value.creditsBalance = "12.50"
        return value
    }

    @Test func diagnosticsIgnoreMissingFilesAndReportCorruptionAndWriteFailure() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let diagnostics = Mutex<[SynchronizationDiagnostic]>([])
        let cache = LocalDisplayCache(directory: root, onDiagnostic: { diagnostic in diagnostics.withLock { $0.append(diagnostic) } })
        #expect(await cache.storage(for: root) == nil)
        await cache.clearAPI()
        #expect(diagnostics.withLock { $0.isEmpty })
        try Data("private-invalid-json".utf8).write(to: root.appendingPathComponent("storage.json"))
        #expect(await cache.storage(for: root) == nil)
        #expect(diagnostics.withLock { $0.first?.operation } == "cache.storage.decode")
        #expect(diagnostics.withLock { $0.first?.reason } == "invalid_document")
        let file = root.appendingPathComponent("not-a-directory")
        try Data().write(to: file)
        try Data("private-auth".utf8).write(to: root.appendingPathComponent("auth.json"))
        let unwritable = LocalDisplayCache(directory: file, onDiagnostic: { diagnostic in diagnostics.withLock { $0.append(diagnostic) } })
        await unwritable.saveAPI(snapshot(), login: CodexLoginStamp(home: root))
        #expect(diagnostics.withLock { $0.last?.operation } == "cache.api.write")
        #expect(!diagnostics.withLock { String(describing: $0) }.contains("private"))
        #expect(!diagnostics.withLock { String(describing: $0) }.contains(root.path))
    }

    @Test func apiCacheSurvivesRestartAndRejectsChangedLogin() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let auth = home.appendingPathComponent("auth.json")
        try Data("test-auth-must-not-be-cached".utf8).write(to: auth)
        let stamp = CodexLoginStamp(home: home)
        let directory = root.appendingPathComponent("cache")
        let cache = LocalDisplayCache(directory: directory)
        await cache.saveAPI(snapshot(), login: stamp)
        let restarted = LocalDisplayCache(directory: directory)
        let cached = await restarted.api(for: stamp)
        #expect(cached?.windows.first?.usedPercent == 42)
        #expect(cached?.planType == "pro" && cached?.creditsBalance == "12.50")
        let contents = try String(contentsOf: directory.appendingPathComponent("api.json"), encoding: .utf8)
        #expect(!contents.contains("raw-response-must-not-be-cached"))
        #expect(!contents.contains("test-auth-must-not-be-cached"))
        try Data("different-auth".utf8).write(to: auth, options: .atomic)
        #expect(await restarted.api(for: CodexLoginStamp(home: home)) == nil)
        try FileManager.default.removeItem(at: auth)
        #expect(await restarted.api(for: CodexLoginStamp(home: home)) == nil)
        await restarted.clearAPI()
        #expect(await restarted.api(for: stamp) == nil)
    }

    @Test func storageCacheSurvivesRestartAndDoesNotCrossRoots() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data(repeating: 42, count: 10_000).write(to: home.appendingPathComponent("sample"))
        try Data("[desktop]\nprojectlessWorkspaceRoot = \"/nonexistent-tokentick-test\"\n".utf8).write(to: home.appendingPathComponent("config.toml"))
        let result = try await CodexStorageScanner.scan(root: home)
        let directory = root.appendingPathComponent("cache")
        await LocalDisplayCache(directory: directory).saveStorage(result)
        let restarted = LocalDisplayCache(directory: directory)
        let cached = await restarted.storage(for: home)
        #expect(cached?.allocatedBytes == result.allocatedBytes)
        #expect(cached?.finishedAt == result.finishedAt)
        #expect(await restarted.storage(for: root) == nil)
        try Data("broken-json".utf8).write(to: directory.appendingPathComponent("storage.json"))
        #expect(await restarted.storage(for: home) == nil)
    }

    @Test func olderStorageCategoriesRemainVisibleUntilReplacement() async throws {
        let home = try root()
        let directory = try root()
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: directory)
        }
        let rootURL = home.standardizedFileURL.resolvingSymlinksInPath()
        let old: [String: Any] = [
            "root": rootURL.absoluteString, "startedAt": 1000, "finishedAt": 1001,
            "issueCount": 0, "issues": [],
            "groups": [["category": "other", "entries": [[
                "url": home.appendingPathComponent("sample").absoluteString,
                "isDirectory": false, "allocatedBytes": 4096, "incomplete": false, "children": []
            ]]]]
        ]
        let file = directory.appendingPathComponent("storage.json")
        let original = try JSONSerialization.data(withJSONObject: old)
        try original.write(to: file)
        let cache = LocalDisplayCache(directory: directory)
        let restored = await cache.storage(for: home)
        #expect(restored?.allocatedBytes == 4096)
        #expect(restored?.groups.map(\.category) == [.other])
        #expect(restored?.projectlessRoot == nil)
        #expect(try Data(contentsOf: file) == original)
        let replacement = CodexStorageSnapshot(root: rootURL,
            projectlessRoot: CodexStorageScanner.projectlessRoot(for: home),
            startedAt: Date(), finishedAt: Date(),
            groups: [.init(category: .generatedContent, entries: [])], issueCount: 0, issues: [])
        await cache.saveStorage(replacement)
        let refreshed = await cache.storage(for: home)
        #expect(refreshed?.groups.map(\.category) == [.generatedContent])
        #expect(refreshed?.finishedAt == replacement.finishedAt)
        let renamed = try JSONDecoder().decode(CodexStorageCategory.self, from: Data("\"visualizations\"".utf8))
        #expect(renamed == .generatedContent)
    }

    @Test func cachedLimitsAreDisplayOnlyUntilAPIConfirmsAccount() {
        var session = CurrentLimitSession()
        let restored = session.restoreCached(snapshot(), now: 10_000)
        #expect(restored)
        #expect(session.snapshot?.observedAt == 1000)
        #expect(session.forecasts.accountID == nil)
        let log = CurrentLimitSnapshot(accountID: nil, observedAt: 10_000, source: "local", scopeKey: "thread:a",
            windows: [.init(limitID: "codex", kind: "primary", usedPercent: 50, durationMinutes: 300, resetsAt: 20_000)], sourceJSON: "{}")
        let logAccepted = session.acceptLog(log, generation: session.generation, now: 10_000)
        #expect(!logAccepted)
        let apiAccepted = session.acceptAPI(snapshot(time: 10_000), generation: session.generation, now: 10_000)
        #expect(apiAccepted)
        #expect(session.forecasts.accountID == "account-a")
        session.invalidate()
        #expect(session.snapshot == nil)
        let futureAccepted = session.restoreCached(snapshot(time: 20_000), now: 10_000)
        #expect(!futureAccepted)
    }

    @Test func missingAndCorruptedAPICacheAreIgnored() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("auth".utf8).write(to: root.appendingPathComponent("auth.json"))
        let cache = LocalDisplayCache(directory: root)
        let stamp = CodexLoginStamp(home: root)
        #expect(await cache.api(for: stamp) == nil)
        try Data("incomplete".utf8).write(to: root.appendingPathComponent("api.json"))
        #expect(await cache.api(for: stamp) == nil)
    }
}
