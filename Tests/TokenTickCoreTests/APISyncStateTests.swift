import Foundation
import Testing
@testable import TokenTickCore

struct APISyncStateTests {
    @Test func totalFailureSurvivesLocalSyncAndRestartWithoutDeletingServerHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("usage.sqlite")
        let store = try UsageStore(databaseURL: url)
        let limits = try JSONDecoder().decode(CodexRateLimits.self, from: Data(CodexAPITests.limits.utf8))
        let daily = try JSONDecoder().decode(CodexDailyUsage.self, from: Data(CodexAPITests.daily.utf8))
        _ = try store.saveAPIObservation(limits: limits, daily: daily, observedAt: Date(timeIntervalSince1970: 100))
        await #expect(throws: CodexAPIError.self) {
            try await CodexAPIClient.synchronize(store: store, executable: root.appendingPathComponent("missing"), codexHome: root)
        }
        let failure = try #require(store.status().apiLastReport)
        #expect(failure.issue != nil && failure.accountID == nil && !failure.accountAvailable)
        #expect(failure.observedAt != nil && failure.dailyBucketCount == nil)
        _ = try await UsageSynchronizer(store: store).synchronize(scope: .local, codexHome: root)
        let reopened = try UsageStore(databaseURL: url)
        #expect(try reopened.status().apiLastReport?.issue == failure.issue)
        #expect(try reopened.status().apiLastReport?.observedAt == failure.observedAt)
        #expect(try reopened.apiDailyUsage().count == 2)
        #expect(try reopened.tableCounts()["weekly_limit_observations"] == 1)
        #expect(try reopened.usageSummaries().isEmpty)
    }

    @Test func latestAccountWithNoCodexWindowCannotBorrowAnotherAccountsWindow() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        let first = try JSONDecoder().decode(CodexRateLimits.self, from: Data(CodexAPITests.limits.utf8))
        _ = try store.saveAPIObservation(limits: first, daily: nil, observedAt: Date(timeIntervalSince1970: 100))
        let second = try JSONDecoder().decode(CodexRateLimits.self, from: Data(#"{"accountId":"account-b","rateLimits":{},"rateLimitsByLimitId":{}}"#.utf8))
        let current = try store.saveAPIObservation(limits: second, daily: nil, observedAt: Date(timeIntervalSince1970: 200))
        let account = try #require(store.status().apiLastReport?.accountID)
        #expect(account == "account-b")
        #expect(current.currentLimits?.windows.isEmpty == true)
        #expect(try store.status().apiLastReport?.currentLimits == nil)
        #expect(try store.tableCounts()["weekly_limit_observations"] == 1)
    }

    @Test func olderReportsCannotRegressNewerFailureAndSuccessCanRecover() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        let limits = try JSONDecoder().decode(CodexRateLimits.self, from: Data(CodexAPITests.limits.utf8))
        try store.saveAPIFailure("newer failure", observedAt: Date(timeIntervalSince1970: 200))
        _ = try store.saveAPIObservation(limits: limits, daily: nil, observedAt: Date(timeIntervalSince1970: 100))
        #expect(try store.status().apiLastReport?.issue == "newer failure")
        _ = try store.saveAPIObservation(limits: limits, daily: nil, observedAt: Date(timeIntervalSince1970: 300))
        try store.saveAPIFailure("late old failure", observedAt: Date(timeIntervalSince1970: 250))
        let report = try #require(store.status().apiLastReport)
        #expect(report.observedAt == 300 && report.accountID == "account-a" && report.issue == nil)
    }

    @Test func legacyReportsDecodeWithoutInventingAnAccountOrTimestamp() throws {
        let json = #"{"accountAvailable":true,"dailyBucketCount":2,"savedWindows":2,"skippedWindows":0,"reconciliation":"unverified_account_and_daily_semantics","issue":null}"#
        let report = try JSONDecoder().decode(APISyncReport.self, from: Data(json.utf8))
        #expect(report.accountID == nil && report.observedAt == nil)
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        #expect(encoded["accountID"] is NSNull && encoded["observedAt"] is NSNull)
    }

    @Test func cancellationDoesNotReplaceTheLastAPIObservationWithAFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        let limits = try JSONDecoder().decode(CodexRateLimits.self, from: Data(CodexAPITests.limits.utf8))
        _ = try store.saveAPIObservation(limits: limits, daily: nil, observedAt: Date(timeIntervalSince1970: 100))
        let executable = root.appendingPathComponent("codex-fixture")
        try "#!/bin/sh\nexec /bin/sleep 30\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let task = Task { try await CodexAPIClient.synchronize(store: store, executable: executable, codexHome: root) }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try store.status().apiLastReport?.observedAt == 100)
        #expect(try store.status().apiLastReport?.issue == nil)
    }
}
