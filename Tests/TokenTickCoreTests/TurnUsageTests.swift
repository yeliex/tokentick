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
        #expect(rows.count == 3)
        #expect(rows.first?["thread_id"] as String? == f.parent)
        #expect(rows.reduce(Int64(0)) { $0 + ($1["total_tokens"] as Int64) } == 360)
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
        #expect(try f.store.tableCounts()["usage"] == 2)
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
        #expect(try f.store.tableCounts()["usage"] == 6)
        let rows = try f.store.pool.read { try Row.fetchAll($0, sql: "SELECT * FROM usage WHERE model='gpt-6-astra' ORDER BY id") }
        #expect(rows.count == 4)
        #expect(rows[0]["input_tokens"] as Int64? == 200_000)
        #expect(rows[0]["is_long_context"] as Bool? == false)
        #expect(rows[2]["is_long_context"] as Bool? == true)
        #expect(rows[3]["tier"] as String? == "fast")
        #expect(rows.allSatisfy { ($0["amount"] as Int64?) != nil })
    }

    @Test func changingTimezoneRebucketsIndividualEventsWithoutLosingDates() throws {
        let f = try Fixture(); defer { f.clean() }
        try f.store.setStatisticsTimezone("UTC")
        let body = f.turn("shared") + f.count(1).replacingOccurrences(of: "00:00:01", with: "15:59:01")
            + f.count(2).replacingOccurrences(of: "00:00:02", with: "16:01:02")
        _ = try f.write(thread: f.parent, created: "2026-09-01T00:00:00Z", body: body)
        _ = try f.scan()
        #expect(try f.store.tableCounts()["usage"] == 2)
        #expect(try f.store.usageReport(UsageQuery(grouping: .total, timezone: "UTC")).unknownDateTokens == 0)
        #expect(try f.store.usageReport(UsageQuery(grouping: .total, timezone: "Asia/Shanghai")).unknownDateTokens == 0)
    }

    @Test func aggregateOverflowFailsWithoutConvertingIndividualTokensToFloatingPoint() throws {
        let f = try Fixture(); defer { f.clean() }
        let input = Int.max / 2 + 100
        _ = try f.write(thread: f.parent, created: "2026-09-01T00:00:00Z", body: f.turn("shared")
            + f.record(1, input: input, output: 20, cumulative: 1)
            + f.record(2, input: input, output: 20, cumulative: 2))
        #expect(try f.scan().issueCount == 0)
        #expect(try f.store.tableCounts()["usage"] == 2)
        #expect(throws: (any Error).self) { try f.total() }
        #expect(try f.store.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM usage WHERE typeof(total_tokens)='integer'") } == 2)
    }

    @Test func separateResponsesWithEqualTokensKeepTheirOrdinalsAndMixedReportsCountOnce() throws {
        let f = try Fixture(); defer { f.clean() }
        func ordinal(_ json: String, _ value: Int) -> String {
            json.replacingOccurrences(of: "{\"timestamp\":", with: "{\"ordinal\":\(value),\"timestamp\":")
        }
        let body = f.turn("shared")
            + ordinal(f.record(1, input: 100, output: 20, cumulative: 120), 10)
            + ordinal(f.count(1), 12)
            + ordinal(f.record(2, input: 100, output: 20, cumulative: 240), 20)
            + ordinal(f.count(2), 22)
        _ = try f.write(thread: f.parent, created: "2026-09-01T00:00:00Z", body: body)
        #expect(try f.scan().issueCount == 0)
        let rows = try f.store.usageRecords(UsageQuery(sort: .automatic)).rows.sorted { $0.id < $1.id }
        #expect(rows.count == 2 && rows.map(\.responseID) == ["resp-1","resp-2"])
        #expect(rows.map(\.sourceOrdinal) == [10,20])
        #expect(try f.total() == 240)
        for (row, ordinal) in zip(rows,[12,22]) {
            let proof = try JSONDecoder().decode(SourceJSON.self, from: Data(row.evidenceJSON.utf8))
            guard case .array(let reports) = proof["alternateReports"] else { Issue.record("缺少双格式报告证据"); continue }
            #expect(reports.count == 1 && reports[0]["ordinal"] == .number(Decimal(ordinal)))
        }
        #expect(try f.scan().insertedRequests == 0)
    }

    @Test func utcHourMinuteAndDateStayConsistentAcrossMidnightAndTimezoneChanges() throws {
        let f = try Fixture(); defer { f.clean() }
        let body = f.turn("shared")
            + f.count(1).replacingOccurrences(of: "2026-09-01T00:00:01Z", with: "2026-09-01T23:59:59Z")
            + f.count(2).replacingOccurrences(of: "2026-09-01T00:00:02Z", with: "2026-09-02T00:00:01Z")
        _ = try f.write(thread: f.parent, created: "2026-09-01T00:00:00Z", body: body)
        #expect(try f.scan().issueCount == 0)
        let rows = try f.store.usageRecords(UsageQuery(timezone: "Asia/Kathmandu")).rows.sorted { $0.id < $1.id }
        #expect(rows.map(\.hour) == [23,0] && rows.map(\.minute) == [59,0])
        #expect(rows.map(\.usageDate) == ["2026-09-01","2026-09-02"])
        #expect(rows.allSatisfy { $0.statisticalDate == "2026-09-02" && $0.sourceOrdinal == nil && $0.responseID == nil })
        let before = try f.store.pool.read { try Row.fetchAll($0, sql: "SELECT usage_date,hour,minute,SUM(total_tokens) AS tokens FROM usage GROUP BY usage_date,hour,minute ORDER BY usage_date,hour,minute") }
        #expect(before.count == 2 && before.allSatisfy { $0["tokens"] as Int64 == 120 })
        try f.store.setStatisticsTimezone("America/New_York")
        _ = try f.store.rebuildStatistics()
        #expect(try f.store.pool.read { try Row.fetchAll($0, sql: "SELECT usage_date,hour,minute,SUM(total_tokens) AS tokens FROM usage GROUP BY usage_date,hour,minute ORDER BY usage_date,hour,minute") } == before)
        #expect(throws: (any Error).self) { try f.store.pool.write { try $0.execute(sql: "UPDATE usage SET hour=24") } }
        #expect(throws: (any Error).self) { try f.store.pool.write { try $0.execute(sql: "UPDATE usage SET minute=60") } }
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
