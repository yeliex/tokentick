import Foundation
import GRDB
import Testing
@testable import TokenTickCore

struct CodexAPITests {
    static let limits = #"{"accountId":"account-a","rateLimits":{"limitId":"legacy","primary":{"usedPercent":99,"windowDurationMins":300,"resetsAt":40000}},"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":12,"windowDurationMins":300,"resetsAt":20000},"secondary":{"usedPercent":23,"windowDurationMins":10080,"resetsAt":800000}}}}"#
    static let daily = #"{"summary":{"lifetimeTokens":9007199254740993},"dailyUsageBuckets":[{"startDate":"2026-09-09","tokens":400},{"startDate":"2026-09-08","tokens":200}],"threadUsage":null}"#

    @Test func observationsAreAccountScopedIdempotentAndNotAddedToLocalUsage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        let limits = try JSONDecoder().decode(CodexRateLimits.self, from: Data(Self.limits.utf8))
        let daily = try JSONDecoder().decode(CodexDailyUsage.self, from: Data(Self.daily.utf8))
        #expect(daily.summary.lifetimeTokens == 9_007_199_254_740_993)
        for _ in 0..<2 {
            let report = try store.saveAPIObservation(limits: limits, daily: daily, observedAt: Date(timeIntervalSince1970: 100))
            #expect(report.dailyBucketCount == 2)
            #expect(report.savedWindows == 2)
        }
        #expect(try store.tableCounts()["api_daily_usage"] == 2)
        #expect(try store.tableCounts()["limit_windows"] == 2)
        #expect(try store.usageSummaries().isEmpty)
        let windows = try store.limitWindows()
        #expect(windows.allSatisfy { $0.limitID == "codex" && $0.tokens == nil && $0.inputAmount == nil })
        #expect(windows.first(where: { $0.kind == "primary" })?.startsAt == 2000)
        let output = try JSONSerialization.jsonObject(with: JSONEncoder().encode(windows)) as? [[String: Any]]
        #expect(output?.first?["tokens"] is NSNull)
        #expect(output?.first?["inputAmount"] is NSNull)
    }

    @Test func missingOrEmptyBucketsPreserveHistoryAndOlderObservationsCannotRegressIt() throws {
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
        #expect(try store.limitWindows().first(where: { $0.kind == "primary" })?.lastUsedPercent == 12)
        for value in ["null", "[]"] {
            let empty = try JSONDecoder().decode(CodexDailyUsage.self, from: Data("{\"summary\":{},\"dailyUsageBuckets\":\(value)}".utf8))
            let report = try store.saveAPIObservation(limits: limits, daily: empty, observedAt: Date(timeIntervalSince1970: 200))
            #expect(report.dailyBucketCount == (value == "null" ? nil : 0))
            #expect(try store.apiDailyUsage().count == 2)
        }
    }

    @Test func earlyResetCreatesAnotherWindowAndMissingWindowShapeIsNotInvented() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        for text in [Self.limits, Self.limits.replacingOccurrences(of: "20000", with: "15000")] {
            let limits = try JSONDecoder().decode(CodexRateLimits.self, from: Data(text.utf8))
            _ = try store.saveAPIObservation(limits: limits, daily: nil, observedAt: Date())
        }
        #expect(try store.limitWindows().count == 3)
        let missing = try JSONDecoder().decode(CodexRateLimits.self, from: Data(#"{"accountId":"account-b","rateLimits":{"limitId":"codex","primary":{"usedPercent":0,"resetsAt":null}}}"#.utf8))
        let report = try store.saveAPIObservation(limits: missing, daily: nil, observedAt: Date())
        #expect(report.skippedWindows == 1)
        #expect(try store.limitWindows().count == 3)
    }

    @Test func latestWindowSelectionDoesNotPreferAnOlderLaterResetOrRecoverMissingWindows() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        let before = try JSONDecoder().decode(CodexRateLimits.self, from: Data(Self.limits.utf8))
        _ = try store.saveAPIObservation(limits: before, daily: nil, observedAt: Date(timeIntervalSince1970: 100))
        let after = try JSONDecoder().decode(CodexRateLimits.self, from: Data(Self.limits.replacingOccurrences(of: "20000", with: "15000").utf8))
        _ = try store.saveAPIObservation(limits: after, daily: nil, observedAt: Date(timeIntervalSince1970: 200))
        #expect(try store.limitWindows(currentOnly: true).first(where: { $0.kind == "primary" })?.resetsAt == 15000)
        let empty = try JSONDecoder().decode(CodexRateLimits.self, from: Data(#"{"accountId":"account-a","rateLimits":{},"rateLimitsByLimitId":{}}"#.utf8))
        _ = try store.saveAPIObservation(limits: empty, daily: nil, observedAt: Date(timeIntervalSince1970: 300))
        #expect(try store.limitWindows(currentOnly: true).isEmpty)
        #expect(try store.limitWindows().count == 3)
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
        #expect(try store.limitWindows().isEmpty)
        let unknown = try JSONDecoder().decode(CodexRateLimits.self, from: Data(Self.limits.replacingOccurrences(of: "\"account-a\"", with: "null").utf8))
        let daily = try JSONDecoder().decode(CodexDailyUsage.self, from: Data(Self.daily.utf8))
        let report = try store.saveAPIObservation(limits: unknown, daily: daily, observedAt: Date())
        #expect(!report.accountAvailable && report.dailyBucketCount == nil)
        #expect(try store.apiDailyUsage().isEmpty)
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
                4) value='\(Self.limits.replacingOccurrences(of: "account-a", with: mode == "switched" ? "account-b" : "account-a"))' ;;
                *) value='\(Self.limits)' ;;
              esac ;;
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
        let report = try await CodexAPIClient(executable: executable, codexHome: root).synchronize(store: store)
        #expect((report.issue == nil) == (mode == "success"))
        #expect(report.issue?.contains("secret-must-not-leak") != true)
        #expect(report.dailyBucketCount == (mode == "success" ? 2 : nil))
        #expect(try store.apiDailyUsage().count == (mode == "success" ? 2 : 0))
        #expect(try store.limitWindows().allSatisfy { $0.accountID == (mode == "switched" ? "account-b" : "account-a") })
        if mode == "success" {
            let raw = try await store.pool.read { db in
                try String.fetchOne(db, sql: "SELECT value FROM app_metadata WHERE key = 'api_daily:account-a'")
            }
            #expect(raw?.contains("threadUsage") == true)
            #expect(raw?.contains("9007199254740993") == true)
        }
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
