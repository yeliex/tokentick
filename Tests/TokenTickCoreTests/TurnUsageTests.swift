import Foundation
import GRDB
import Testing
@testable import TokenTickCore

struct TurnUsageTests {
    @Test func forkCopiesUseOriginalCompleteTurnAndOriginalCanKeepGrowing() throws {
        let f = try Fixture(); defer { f.clean() }
        let original = try f.write(thread: f.parent, created: "2026-09-01T00:00:00Z", body: f.turn("shared") + f.count(1) + f.count(2))
        _ = try f.write(thread: f.child, created: "2026-09-02T00:00:00Z", body:
            (f.turn("shared") + f.count(1)).replacingOccurrences(of: "2026-09-01", with: "2026-09-02") + f.turn("child-only") + f.count(3))
        #expect(try f.scan().issueCount == 0)
        #expect(try f.total() == 360)
        #expect(try f.store.tableCounts()["turn_usage"] == 2)
        try f.append(f.count(3), to: original)
        #expect(try f.scan().issueCount == 0)
        #expect(try f.total() == 480)
        let rows = try f.store.pool.read { try Row.fetchAll($0, sql: "SELECT * FROM usage WHERE turn_id='shared'") }
        #expect(rows.count == 1)
        #expect(rows.first?["thread_id"] as String? == f.parent)
        #expect(rows.first?["total_tokens"] as Int64? == 360)
        #expect(try f.store.threadInfo(ids: [f.parent])[f.parent]?.lastActiveAt == RolloutParser.parseDate("2026-09-01T00:00:03Z")?.timeIntervalSince1970)
        #expect(try f.scan().insertedRequests == 0)
    }

    @Test func earlierOriginalArrivingLaterReplacesOwnerDateAndPartialCopy() throws {
        let f = try Fixture(); defer { f.clean() }
        _ = try f.write(thread: f.child, created: "2026-09-02T00:00:00Z", body:
            (f.turn("shared") + f.count(1)).replacingOccurrences(of: "2026-09-01", with: "2026-09-02"))
        _ = try f.scan()
        _ = try f.write(thread: f.parent, created: "2026-09-01T00:00:00Z", body: f.turn("shared") + f.count(1) + f.count(2))
        let reopened = try UsageStore(databaseURL: f.store.databaseURL)
        #expect(try LocalUsageScanner(store: reopened).scan(codexHome: f.root).issueCount == 0)
        #expect(try f.total() == 240)
        let row = try f.store.pool.read { try Row.fetchOne($0, sql: "SELECT thread_id,usage_date FROM usage") }
        #expect(row?["thread_id"] as String? == f.parent)
        #expect(row?["usage_date"] as String? == "2026-09-01")
        #expect(try f.store.tableCounts()["turn_usage"] == 1)
    }

    @Test func mixedFormatsWithDifferentCumulativeBaselinesSurviveRestartAndReplay() throws {
        let f = try Fixture(); defer { f.clean() }
        let first = f.record(1, input: 171_813, output: 231, cumulative: 172_044)
        let legacy = f.count(1, input: 171_813, output: 231, cumulative: 419_766_598)
        let second = f.record(2, input: 178_000, output: 370, cumulative: 350_414)
            + f.count(2, input: 178_000, output: 370, cumulative: 419_944_968)
        let file = try f.write(thread: f.parent, created: "2026-09-01T00:00:00Z", body: f.turn("shared") + first)
        _ = try f.scan()
        try f.append(legacy + second, to: file)
        let reopened = try UsageStore(databaseURL: f.store.databaseURL)
        #expect(try LocalUsageScanner(store: reopened).scan(codexHome: f.root).issueCount == 0)
        #expect(try f.total() == 350_414)
        #expect(try f.store.tableCounts()["usage"] == 1)
        _ = try f.write(thread: f.parent, created: "2026-09-01T00:00:00Z", body: f.turn("shared") + first + legacy + second)
        #expect(try f.scan().issueCount == 0)
        #expect(try f.total() == 350_414)
    }

    @Test func oneTurnKeepsModelDayAndPricingModesWithoutUsingTurnTotalAsContext() throws {
        let f = try Fixture(); defer { f.clean() }
        let base = f.turn("shared", model: "gpt-6-astra")
            + f.count(1, input: 200_000, output: 20, cumulative: 200_020)
            + f.count(2, input: 200_000, output: 20, cumulative: 400_040)
        let long = f.count(3, input: 300_000, output: 20, cumulative: 700_060)
        let fast = f.turn("shared", model: "gpt-6-astra", tier: "priority")
            + f.count(4, input: 300_000, output: 20, cumulative: 1_000_080)
        let other = f.turn("shared", model: "gpt-5.5") + f.count(5, cumulative: 1_000_200)
        let nextDay = f.count(6, cumulative: 1_000_320).replacingOccurrences(of: "2026-09-01", with: "2026-09-02")
        _ = try f.write(thread: f.parent, created: "2026-09-01T00:00:00Z", body: base + long + fast + other + nextDay)
        #expect(try f.scan().issueCount == 0)
        #expect(try f.store.tableCounts()["turn_usage"] == 1)
        #expect(try f.store.tableCounts()["usage"] == 5)
        let rows = try f.store.pool.read { try Row.fetchAll($0, sql: "SELECT * FROM usage WHERE model='gpt-6-astra' ORDER BY id") }
        #expect(rows.count == 3)
        #expect(rows[0]["input_tokens"] as Int64? == 400_000)
        #expect(rows[0]["is_long_context"] as Bool? == false)
        #expect(rows[1]["is_long_context"] as Bool? == true)
        #expect(rows[2]["is_fast"] as Bool? == true)
        #expect(rows.allSatisfy { ($0["amount"] as Int64?) != nil })
    }

    @Test func changingQueryTimezoneDoesNotAssignAnEntireCrossMidnightPartToOneDay() throws {
        let f = try Fixture(); defer { f.clean() }
        try f.store.setStatisticsTimezone("UTC")
        let body = f.turn("shared") + f.count(1).replacingOccurrences(of: "00:00:01", with: "15:59:01")
            + f.count(2).replacingOccurrences(of: "00:00:02", with: "16:01:02")
        _ = try f.write(thread: f.parent, created: "2026-09-01T00:00:00Z", body: body)
        _ = try f.scan()
        #expect(try f.store.tableCounts()["usage"] == 1)
        #expect(try f.store.usageReport(UsageQuery(grouping: .total, timezone: "UTC")).unknownDateTokens == 0)
        #expect(try f.store.usageReport(UsageQuery(grouping: .total, timezone: "Asia/Shanghai")).unknownDateTokens == 240)
    }

    @Test func turnTokenOverflowRollsBackInsteadOfBecomingFloatingPoint() throws {
        let f = try Fixture(); defer { f.clean() }
        let input = Int.max / 2 + 100
        _ = try f.write(thread: f.parent, created: "2026-09-01T00:00:00Z", body: f.turn("shared")
            + f.record(1, input: input, output: 20, cumulative: 1)
            + f.record(2, input: input, output: 20, cumulative: 2))
        #expect(throws: (any Error).self) { try f.scan() }
        #expect(try f.total() == 0)
        #expect(try f.store.tableCounts()["turn_usage"] == 0)
        #expect(try f.store.tableCounts()["scan_files"] == 0)
    }

    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store: UsageStore
        let parent = "00000000-0000-0000-0000-000000000001"
        let child = "00000000-0000-0000-0000-000000000002"
        init() throws {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
            store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        }
        func turn(_ id: String, model: String = "gpt-5.5", tier: String = "default") -> String {
            "{\"type\":\"turn_context\",\"payload\":{\"turn_id\":\"\(id)\",\"model\":\"\(model)\",\"service_tier\":\"\(tier)\"}}\n"
        }
        func tokens(_ input: Int, _ output: Int, _ total: Int) -> String {
            "{\"input_tokens\":\(input),\"output_tokens\":\(output),\"cached_input_tokens\":0,\"cache_write_input_tokens\":0,\"reasoning_output_tokens\":0,\"total_tokens\":\(total)}"
        }
        func count(_ n: Int, input: Int = 100, output: Int = 20, cumulative: Int? = nil) -> String {
            "{\"timestamp\":\"2026-09-01T00:00:0\(n)Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":\(tokens(input, output, input + output)),\"total_token_usage\":\(tokens(input * n, output * n, cumulative ?? 120 * n))}}}\n"
        }
        func record(_ n: Int, input: Int, output: Int, cumulative: Int) -> String {
            "{\"timestamp\":\"2026-09-01T00:00:0\(n)Z\",\"type\":\"token_usage_record\",\"payload\":{\"thread_id\":\"\(parent)\",\"turn_id\":\"shared\",\"response_id\":\"resp-\(n)\",\"usage\":\(tokens(input, output, input + output)),\"thread_token_usage\":\(tokens(input, output, cumulative))}}\n"
        }
        func write(thread: String, created: String, body: String) throws -> URL {
            let name = "rollout-" + created.replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: "Z", with: "") + "-" + thread + ".jsonl"
            let url = root.appendingPathComponent("sessions/" + name)
            let header = "{\"timestamp\":\"\(created)\",\"type\":\"session_meta\",\"payload\":{\"id\":\"\(thread)\",\"timestamp\":\"\(created)\"}}\n"
            try Data((header + body).utf8).write(to: url, options: .atomic)
            return url
        }
        func append(_ body: String, to url: URL) throws {
            let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: Data(body.utf8))
        }
        func scan() throws -> ScanReport { try LocalUsageScanner(store: store).scan(codexHome: root) }
        func total() throws -> Int64 { try store.pool.read { try Int64.fetchOne($0, sql: "SELECT COALESCE(SUM(total_tokens),0) FROM usage") ?? 0 } }
        func clean() { try? FileManager.default.removeItem(at: root) }
    }
}
