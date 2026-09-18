import Foundation
import GRDB
import Testing
import Synchronization
@testable import TokenTickCore

struct CodexAPITests {
    @Test(arguments: ["Codex.app", "ChatGPT.app"])
    func discoversBundledExecutableWithoutPATH(app: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let system = root.appendingPathComponent("Applications")
        let user = root.appendingPathComponent("User/Applications")
        let cli = user.appendingPathComponent("\(app)/Contents/Resources/codex")
        try FileManager.default.createDirectory(at: cli.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: cli)
        #expect(throws: CodexAPIError.self) {
            try CodexAPIClient.resolveExecutable(path: "", applicationDirectories: [system, user])
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        #expect(try CodexAPIClient.resolveExecutable(path: "", applicationDirectories: [system, user]) == cli)
        #expect(throws: CodexAPIError.self) {
            try CodexAPIClient.resolveExecutable(explicit: root.appendingPathComponent("missing"), path: "", applicationDirectories: [user])
        }
        let pathCLI = root.appendingPathComponent("codex")
        try FileManager.default.copyItem(at: cli, to: pathCLI)
        #expect(try CodexAPIClient.resolveExecutable(path: root.path, applicationDirectories: [user]) == pathCLI)
        #expect(try CodexAPIClient.resolveExecutable(explicit: cli, path: root.path) == cli)
    }

    @Test func priceDiagnosticsPreserveHTTPStatusAndCancellation() {
        let failure = SynchronizationDiagnostic(error: PriceSynchronizer.SyncError.httpStatus(503), operation: "sync.prices")
        #expect(failure.code == 503)
        #expect(failure.reason == "http_status")
        #expect(SynchronizationDiagnostic(error: CancellationError(), operation: "sync.prices").isCancellation)
        #expect(SynchronizationDiagnostic(error: URLError(.cancelled), operation: "sync.prices").isCancellation)
    }

    @Test func scanDiagnosticsCountAllIssuesWithoutIncludingPrivateText() {
        var report = ScanReport()
        for _ in 0..<150 { report.addIssue("parse", ScanIssue(fileName: "private-file", line: 1, message: "private-body")) }
        report.addIssue("empty_source", ScanIssue(fileName: "private-root", line: nil, message: "empty"))
        #expect(report.issues.count == 100)
        #expect(report.diagnosticCounts == ["parse": 150])
    }

    @Test func diagnosticsExcludePrivateErrorContentsAndKeepRPCCode() {
        let error = NSError(domain: "secret-account", code: 42, userInfo: [NSLocalizedDescriptionKey: "secret-token /Users/private SQL"])
        let diagnostic = SynchronizationDiagnostic(error: error, operation: "sync.logs")
        #expect(diagnostic.reason == "operation_failed")
        #expect(diagnostic.code == 42)
        #expect(!String(describing: diagnostic).contains("secret"))
        #expect(!String(describing: diagnostic).contains("/Users"))
        let rpc = SynchronizationDiagnostic(error: CodexAPIError.rpc(-32601), operation: "api.daily_usage")
        #expect(rpc.reason == "rpc_error")
        #expect(rpc.code == -32601)
    }

    static let limits = #"{"accountId":"account-a","rateLimits":{"limitId":"legacy","primary":{"usedPercent":99,"windowDurationMins":300,"resetsAt":40000}},"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":12,"windowDurationMins":300,"resetsAt":20000},"secondary":{"usedPercent":23,"windowDurationMins":10080,"resetsAt":800000}}}}"#
    static let daily = #"{"summary":{"lifetimeTokens":9007199254740993},"dailyUsageBuckets":[{"startDate":"2026-09-09","tokens":400},{"startDate":"2026-09-08","tokens":200}],"threadUsage":null}"#

    @Test func observationsAreAccountScopedIdempotentAndNotAddedToLocalUsage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        let limits = try JSONDecoder().decode(CodexRateLimits.self, from: Data(Self.limits.utf8))
        let daily = try JSONDecoder().decode(CodexDailyUsage.self, from: Data(Self.daily.utf8))
        #expect(daily.summary.lifetimeTokens == 9_007_199_254_740_993)
        for attempt in 0..<2 {
            let report = try store.saveAPIObservation(limits: limits, daily: daily, observedAt: Date(timeIntervalSince1970: 100))
            #expect(report.dailyBucketCount == 2)
            #expect(report.savedWindows == 0)
            #expect(report.currentLimits?.windows.count == 2)
        }
        #expect(try store.tableCounts()["api_daily_usage"] == nil)
        #expect(try store.tableCounts()["weekly_limit_cycles"] == 0)
        #expect(try store.usageSummaries().isEmpty)
        #expect(try store.weeklyLimitHistory().rows.isEmpty)
        #expect(try store.status().apiLastReport?.currentLimits == nil)
        #expect(try UsageStore(databaseURL: store.databaseURL).apiDailyUsage().isEmpty)

    }

    @Test func emptyBucketsClearMemoryAndOlderObservationsCannotRegressIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        let limits = try JSONDecoder().decode(CodexRateLimits.self, from: Data(Self.limits.utf8))
        let daily = try JSONDecoder().decode(CodexDailyUsage.self, from: Data(Self.daily.utf8))
        _ = try store.saveAPIObservation(limits: limits, daily: daily, observedAt: Date(timeIntervalSince1970: 100))
        let oldLimits = try JSONDecoder().decode(CodexRateLimits.self, from: Data(Self.limits.replacingOccurrences(of: "\"usedPercent\":12", with: "\"usedPercent\":1").utf8))
        let oldDaily = try JSONDecoder().decode(CodexDailyUsage.self, from: Data(Self.daily.replacingOccurrences(of: "\"tokens\":400", with: "\"tokens\":1").utf8))
        _ = try store.saveAPIObservation(limits: oldLimits, daily: oldDaily, observedAt: Date(timeIntervalSince1970: 50))
        #expect(try store.apiDailyUsage().first?.tokens == 400)
        #expect(try store.status().apiLastReport?.observedAt == 100)
        for value in ["null", "[]"] {
            let empty = try JSONDecoder().decode(CodexDailyUsage.self, from: Data("{\"summary\":{},\"dailyUsageBuckets\":\(value)}".utf8))
            let report = try store.saveAPIObservation(limits: limits, daily: empty, observedAt: Date(timeIntervalSince1970: 200))
            #expect(report.dailyBucketCount == (value == "null" ? nil : 0))
            #expect(try store.apiDailyUsage().isEmpty)
        }
    }

    @Test func realTimeSnapshotsAreNotRestoredAndMissingWeeklyBoundaryIsNotInvented() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        let missing = try JSONDecoder().decode(CodexRateLimits.self, from: Data(#"{"accountId":"account-b","rateLimits":{"limitId":"codex","primary":{"usedPercent":0,"windowDurationMins":10080,"resetsAt":null}}}"#.utf8))
        let report = try store.saveAPIObservation(limits: missing, daily: nil, observedAt: Date())
        #expect(report.skippedWindows == 1)
        #expect(report.currentLimits?.windows.count == 1)
        #expect(try store.tableCounts()["weekly_limit_cycles"] == 0)
        #expect(try store.status().apiLastReport?.currentLimits == nil)
    }

    @Test func invalidDailyResponseRollsBackAndUnknownAccountDoesNotAcquireOtherAccountsHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        let limits = try JSONDecoder().decode(CodexRateLimits.self, from: Data(Self.limits.utf8))
        for text in [Self.daily.replacingOccurrences(of: "2026-09-09", with: "2026-09-08"),
                     Self.daily.replacingOccurrences(of: "2026-09-09", with: "2026-02-31"),
                     Self.daily.replacingOccurrences(of: "\"tokens\":400", with: "\"tokens\":-1")] {
            let daily = try JSONDecoder().decode(CodexDailyUsage.self, from: Data(text.utf8))
            #expect(throws: CodexAPIError.self) {
                try store.saveAPIObservation(limits: limits, daily: daily, observedAt: Date())
            }
        }
        #expect(try store.tableCounts()["weekly_limit_cycles"] == 0)
        let unknown = try JSONDecoder().decode(CodexRateLimits.self, from: Data(Self.limits.replacingOccurrences(of: "\"account-a\"", with: "null").utf8))
        let daily = try JSONDecoder().decode(CodexDailyUsage.self, from: Data(Self.daily.utf8))
        let report = try store.saveAPIObservation(limits: unknown, daily: daily, observedAt: Date())
        #expect(!report.accountAvailable && report.dailyBucketCount == 2)
        #expect(try store.apiDailyUsage().count == 2)
        #expect(try store.apiDailyUsage().allSatisfy { $0.accountID == nil })
    }

    @Test(arguments: ["switched", "unsupported", "success"])
    func stdioIntegrationPreservesStatisticalEvidenceAndHandlesPartialAvailability(mode: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        let executable = root.appendingPathComponent("codex-fixture")
        let script = """
        #!/bin/sh
        i=0
        while IFS= read -r line; do
          case "$line" in
            *'"method":"initialized"'*) continue ;;
          esac
          i=$((i + 1))
          case "$line" in
            *'account/rateLimits/read'*)
              case "$i" in
                5) value='\(Self.limits.replacingOccurrences(of: "account-a", with: mode == "switched" ? "account-b" : "account-a"))' ;;
                *) value='\(Self.limits)' ;;
              esac ;;
            *'account/read'*) value='{"account":{"type":"chatgpt","email":"member@example.com"}}' ;;
            *'account/usage/read'*) value='\(Self.daily)' ;;
            *) value='{}' ;;
          esac
          printf '%s\\n' '{"method":"notification/example","params":{}}'
          if [ "$i" = 3 ] && [ '\(mode)' = unsupported ]; then
            printf '{"id":%s,"error":{"code":-32601,"message":"secret-must-not-leak"}}\\n' "$i"
            continue
          fi
          printf '{"id":%s,"result":%s}\\n' "$i" "$value"
        done
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let diagnostics = Mutex<[SynchronizationDiagnostic]>([])
        let report = try await CodexAPIClient.synchronize(store: store, executable: executable, codexHome: root,
            onDiagnostic: { diagnostic in diagnostics.withLock { $0.append(diagnostic) } })
        let captured = diagnostics.withLock { $0 }
        if mode == "unsupported" {
            #expect(captured.count == 1)
            #expect(captured.first?.operation == "api.daily_usage")
            #expect(captured.first?.code == -32601)
        } else if mode == "success" { #expect(captured.isEmpty) }
        else { #expect(captured.first?.reason == "account_changed") }
        #expect((report.issue == nil) == (mode == "success"))
        #expect(report.issue?.contains("secret-must-not-leak") != true)
        #expect(report.accountEmail == (mode == "switched" ? nil : "member@example.com"))
        #expect(report.dailyBucketCount == (mode == "success" ? 2 : nil))
        #expect(try store.apiDailyUsage().count == (mode == "success" ? 2 : 0))
        #expect(report.currentLimits?.accountID == (mode == "switched" ? "account-b" : "account-a"))
        if mode == "success" {
            let raw = try await store.pool.read { db in
                try String.fetchOne(db, sql: "SELECT value FROM app_metadata WHERE key = 'api_daily:account-a'")
            }
            #expect(raw == nil)
            #expect(store.apiMemory.withLock { $0.daily?.summary.lifetimeTokens } == 9_007_199_254_740_993)
        }
    }

    @Test func dailyDifferenceCountsLocalUnknownModelsAndRemoteLogsOnlyOnceAndNeverPersists() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        try store.pool.write { db in
            try db.execute(sql: """
                INSERT INTO usage(source_line,rollout_id,account_id,usage_date,model,total_tokens,source,pricing_source) VALUES
                    (1,'known','account-a','2026-09-09','m',100,'local','{}'),
                    (1,'remote',NULL,'2026-09-09',NULL,150,'local','{}'),
                    (1,'other','account-b','2026-09-09','m',800,'local','{}'),
                    (1,'more','account-a','2026-09-08','m',250,'local','{}');
                """)
        }
        let limits = try JSONDecoder().decode(CodexRateLimits.self, from: Data(Self.limits.utf8))
        let daily = try JSONDecoder().decode(CodexDailyUsage.self, from: Data(Self.daily.utf8))
        _ = try store.saveAPIObservation(limits: limits, daily: daily, observedAt: Date())
        let days = try store.apiDailyUsage()
        #expect(days[0].localTokens == 250 && days[0].unknownAccountLocalTokens == 150 && days[0].otherTokens == 150)
        #expect(days[1].differenceTokens == -50 && days[1].otherTokens == 0)
        #expect(try store.tableCounts()["usage"] == 4 && store.tableCounts()["api_daily_usage"] == nil)
        #expect(try UsageStore(databaseURL: store.databaseURL).apiDailyUsage().isEmpty)
        #expect(try store.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM app_metadata WHERE key LIKE 'api_daily:%'") } == 0)
    }

    @Test func stalledAppServerHasBoundedTimeout() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("codex-fixture")
        try "#!/bin/sh\nexec /bin/sleep 5\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let started = Date()
        #expect(throws: CodexAPIError.self) { try CodexAPISession(executable: executable, codexHome: root, timeout: 0.05) }
        #expect(Date().timeIntervalSince(started) < 2)
    }
}
