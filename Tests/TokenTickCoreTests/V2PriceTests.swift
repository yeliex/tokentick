import Foundation
import GRDB
import Testing
@testable import TokenTickCore

struct V2PriceTests {
    private static let document = Data(#"""
        {"openai":{"models":{"gpt-6.2-sol":{"id":"gpt-6.2-sol","release_date":"2026-11-17",
          "cost":{"text":{"input":{"price":2,"cache":{"read":0.1,"write":{"12h":5,"30m":2.5}},
          "overrides":[{"when":{"context":{"gt":272000}},"price":4,"cache":{"read":0.2,"write":{"30m":5}}}]},
          "output":{"price":10,"overrides":[{"when":{"context":{"gt":272000}},"price":15}]}},
          "multipliers":[{"when":{"service_tier":{"equals":"priority"}},"factor":{"text":2}},
          {"when":{"service_tier":{"equals":"ultrafast"},"date":{"lt":"2027-03-01"}},"factor":{"text":3}},
          {"when":{"service_tier":{"equals":"ultrafast"},"date":{"gte":"2027-03-01"}},"factor":{"text":6}},
          {"when":{"not":{"region":{"equals":"global"}}},"factor":{"text":1.1}}]}}}}}
        """#.utf8)

    @Test func presynchronizedRateTakesEffectAtPublishedBoundary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        let before = try #require(DateParsing.parseTimestamp("2027-03-01T07:59:59Z"))
        let boundary = try #require(DateParsing.parseTimestamp("2027-03-01T08:00:00Z"))
        let late = try #require(DateParsing.parseTimestamp("2027-03-03T01:00:00Z"))
        let initial = try ModelsDevPricesV2.decode(Self.document, observedAt: before)
        #expect(initial.filter { $0.tier == "ultrafast" }.map(\.rates.input) == [6, 6, 12])
        let fast = try #require(initial.first { $0.tier == "fast" })
        #expect(fast.rates.cacheWrite == 5 && fast.long.cacheWrite == 10 && fast.long.output == 30)
        _ = try store.savePrices(initial, date: "2027-03-01", observedAt: before)
        #expect(try store.hasSyncedPrices(on: "2027-03-01"))
        try store.pool.read { db throws -> Void in
            #expect(try UsageStore.modelPrice(db: db, model: "gpt-6.2-sol", date: "2027-03-01", tier: "ultrafast",
                                            occurredAt: before.timeIntervalSince1970)?.rates.input == 6)
            #expect(try UsageStore.modelPrice(db: db, model: "gpt-6.2-sol", date: "2027-03-01", tier: "ultrafast",
                                            occurredAt: boundary.timeIntervalSince1970)?.rates.input == 12)
        }
        let later = try ModelsDevPricesV2.decode(Self.document, observedAt: late)
        #expect(try store.savePrices(later, date: "2027-03-03", observedAt: late).insertedSnapshots == 0)
    }

    @Test func announcedRatesCanChangeUntilTheyTakeEffect() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        let boundary = try #require(DateParsing.parseTimestamp("2027-03-01T08:00:00Z"))
        let movedBoundary = boundary.addingTimeInterval(86_400)
        func sync(_ day: String, from document: Data) throws {
            let observation = try #require(DateParsing.parseTimestamp(day + "T12:00:00Z"))
            let prices = try ModelsDevPricesV2.decode(document, observedAt: observation)
            _ = try store.savePrices(prices, date: day, observedAt: observation)
        }
        func price(_ time: Date) throws -> Decimal? {
            try store.pool.read { db in
                try UsageStore.modelPrice(db: db, model: "gpt-6.2-sol", date: "2027-03-01", tier: "ultrafast",
                                          occurredAt: time.timeIntervalSince1970)?.rates.input
            }
        }
        func revise(_ original: Data, _ from: String, _ to: String) -> Data {
            Data(String(decoding: original, as: UTF8.self).replacingOccurrences(of: from, with: to).utf8)
        }
        try sync("2027-02-24", from: Self.document)
        let changedRate = revise(Self.document, #""text":6"#, #""text":7"#)
        try sync("2027-02-25", from: changedRate)
        #expect(try price(boundary) == 14)
        let moved = revise(changedRate, "2027-03-01", "2027-03-02")
        try sync("2027-02-26", from: moved)
        #expect(try price(boundary) == 6)
        #expect(try price(movedBoundary) == 14)
        try sync("2027-03-03", from: revise(moved, #""text":7"#, #""text":8"#))
        #expect(try price(movedBoundary) == 14)
        #expect(try price(movedBoundary.addingTimeInterval(86_400 * 2)) == 16)
    }

    @Test func offlineRatesSwitchWithAnEmptyOrOlderPriceStore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        let boundary = try #require(DateParsing.parseTimestamp("2027-03-01T08:00:00Z"))
        let old = UsagePricingTests.price(model: "gpt-6.2-sol", date: "2027-02-24", tier: "ultrafast",
                                         rates: PriceRates(input: 6, output: 30, cacheRead: 0.3, cacheWrite: 7.5))
        func check() throws {
            try store.pool.read { db in
                for (model, shortInput, longInput) in [("gpt-6.2-sol", 12, 24), ("gpt-6.2-astra", 48, 96)] {
                    let before = try UsageStore.modelPrice(db: db, model: model, date: "2027-03-01", tier: "ultrafast",
                        occurredAt: boundary.addingTimeInterval(-1).timeIntervalSince1970)
                    let after = try UsageStore.modelPrice(db: db, model: model, date: "2027-03-01", tier: "ultrafast",
                        occurredAt: boundary.timeIntervalSince1970)
                    #expect(before?.rates.input == Decimal(shortInput / 2))
                    #expect(after?.rates.input == Decimal(shortInput))
                    #expect(after?.long.input == Decimal(longInput))
                    #expect(after?.source.isBundled == true)
                }
            }
        }
        try check()
        _ = try store.savePrices([old], date: old.date)
        try check()
    }

    @Test func historicalBackfillPreservesKnownMoneyAndFillsOnlyGaps() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageStore(databaseURL: root.appendingPathComponent("usage.sqlite"))
        try store.pool.write { db in
            try db.execute(sql: """
                INSERT INTO usage(source_line,rollout_id,model,tier,usage_date,input_tokens,output_tokens,cache_read_tokens,
                    cache_write_tokens,total_tokens,source,input_amount,amount,api_amount)
                VALUES (1,'a','gpt-6.2-sol','ultrafast','2026-11-24',100,10,0,0,110,'local',1,2,3),
                       (2,'a','gpt-6.2-sol','ultrafast','2026-11-24',100,10,0,0,110,'local',5,NULL,NULL)
                """)
        }
        let report = try store.repriceUsage(onlyMissing: true)
        #expect(report.examined == 1 && report.changed == 1)
        let rows = try store.usageRecords().rows
        #expect(rows.first { $0.sourceLine == 1 }?.amountNanoUSD == 2)
        #expect(rows.first { $0.sourceLine == 1 }?.apiAmountNanoUSD == 3)
        #expect(rows.first { $0.sourceLine == 2 }?.inputAmountNanoUSD == 5)
        #expect(rows.first { $0.sourceLine == 2 }?.amountNanoUSD == 300_005)
    }
}
