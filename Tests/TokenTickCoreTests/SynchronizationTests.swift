import Foundation
import Testing
import Synchronization
@testable import TokenTickCore

struct SynchronizationTests {
    @Test func localOnlySyncKeepsSuccessfulPrefixAndPersistsPartialReport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        try writeLog(root: root, malformed: true)
        let report = try await UsageSynchronizer(store: store).synchronize(scope: .local, codexHome: root)
        #expect(report.scan?.insertedRequests == 1 && report.scan?.issueCount == 1)
        #expect(report.prices == nil && report.api == nil)
        #expect(report.statistics?.rebuilt == true && report.issues.count == 1)
        #expect(report.finishedAt != nil)
        #expect(try store.usageSummaries(grouping: .total).first?.totalTokens == 10)
        #expect(try store.lastSynchronizationReport()?.scan?.issueCount == 1)
        let repeated = try await UsageSynchronizer(store: store).synchronize(scope: .local, codexHome: root)
        #expect(repeated.scan?.insertedRequests == 0)
        #expect(try store.usageSummaries(grouping: .total).first?.totalTokens == 10)
    }

    @Test func unavailableAPIStillLeavesLocalFactsPricesAndStatisticsUsable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        let date = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))
        _ = try store.savePrices(ModelsDevPrices.decode(Data(UsagePricingTests.document.utf8), date: date), date: date)
        try writeLog(root: root, malformed: false)
        let report = try await UsageSynchronizer(store: store).synchronize(codexHome: root,
            codexExecutable: root.appendingPathComponent("missing-codex"))
        #expect(report.scan?.insertedRequests == 1)
        #expect(report.prices?.alreadySynced == true)
        #expect(report.reprice?.examined == 1 && report.reprice?.fullyPriced == 1)
        #expect(report.api == nil && report.issues.count == 1)
        #expect(report.statistics?.rebuilt == true)
        #expect(try store.usageSummaries(grouping: .total).first?.knownAmountNanoUSD == 180_000)
        #expect(try store.lastSynchronizationReport()?.scope == .all)
    }

    @Test func publishesCurrentLimitsBeforeScanningLocalUsage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        let date = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))
        _ = try store.savePrices(ModelsDevPrices.decode(Data(UsagePricingTests.document.utf8), date: date), date: date)
        try writeLog(root: root, malformed: false)
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
            *'account/rateLimits/read'*) value='\(CodexAPITests.limits)' ;;
            *'account/usage/read'*) value='\(CodexAPITests.daily)' ;;
            *) value='{}' ;;
          esac
          printf '{"id":%s,"result":%s}\\n' "$i" "$value"
        done
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let published = Mutex(false)
        let report = try await UsageSynchronizer(store: store).synchronize(codexHome: root,
            codexExecutable: executable, onCurrentLimits: { snapshot in
                #expect(snapshot?.accountID == "account-a")
                #expect((try? store.tableCounts()["usage"]) == 0)
                published.withLock { $0 = true }
            })
        #expect(published.withLock { $0 })
        #expect(report.scan?.insertedRequests == 1)
        #expect(report.api?.currentLimits?.accountID == "account-a")
    }

    private func writeLog(root: URL, malformed: Bool) throws {
        let folder = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let id = "00000000-0000-0000-0000-000000000007"
        let date = Date().formatted(.iso8601)
        let usage = #"{"input_tokens":8,"output_tokens":2,"cached_input_tokens":0,"cache_write_input_tokens":0,"total_tokens":10}"#
        let text = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(id)\"}}\n"
            + "{\"type\":\"turn_context\",\"payload\":{\"turn_id\":\"turn\",\"model\":\"gpt-6-astra\",\"service_tier\":\"default\"}}\n"
            + "{\"timestamp\":\"\(date)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":\(usage),\"last_token_usage\":\(usage)}}}\n"
            + (malformed ? "{bad-json}\n" : "")
        try text.write(to: folder.appendingPathComponent("rollout-2026-09-09T00-00-00-\(id).jsonl"), atomically: true, encoding: .utf8)
    }
}
