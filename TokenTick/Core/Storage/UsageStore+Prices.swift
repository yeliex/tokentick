import Foundation
import GRDB

public struct PriceSyncReport: Codable, Sendable {
    public let date: String
    public let alreadySynced: Bool
    public let models: Int
    public let insertedSnapshots: Int
    public let unsupportedContextModels: [String]
    public let missingPriceModels: [String]
}

public struct PriceEntry: Encodable, Sendable {
    public let model: String
    public let date: String
    public let tier: String
    public let rates: [String: String?]
    public let longContextThreshold: Int64?

    private enum CodingKeys: String, CodingKey { case model, date, tier, rates, longContextThreshold }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(model, forKey: .model)
        try values.encode(date, forKey: .date)
        try values.encode(tier, forKey: .tier)
        try values.encode(rates, forKey: .rates)
        try values.encode(longContextThreshold, forKey: .longContextThreshold)
    }
}

extension UsageStore {
    func hasSyncedPrices(on date: String) throws -> Bool {
        try pool.read { db in
            try Self.hasSyncedPrices(on: date, db: db)
        }
    }

    private static func hasSyncedPrices(on date: String, db: Database) throws -> Bool {
        guard try String.fetchOne(db, sql: "SELECT value FROM app_metadata WHERE key = 'prices_last_success_date'") == date else { return false }
        return try String.fetchOne(db, sql: "SELECT value FROM app_metadata WHERE key = 'prices_last_success_source'") == ModelsDevPricesV2.sourceURL
    }

    func savePrices(_ prices: [ModelPrice], date: String, observedAt: Date? = nil) throws -> PriceSyncReport {
        guard let midnight = DateParsing.parseTimestamp(date + "T00:00:00Z") else { throw PriceError.invalidDate }
        let observation = observedAt ?? midnight
        let observedTimestamp = observation.timeIntervalSince1970
        return try FileWriteLock(url: databaseURL.appendingPathExtension("write.lock")).withLock {
            try pool.write { db in
                if try Self.hasSyncedPrices(on: date, db: db) {
                    return PriceSyncReport(date: date, alreadySynced: true, models: Set(prices.map(\.model)).count, insertedSnapshots: 0,
                                           unsupportedContextModels: prices.filter { $0.contextRule == .unsupported && $0.rates != .unknown }.map(\.model),
                                           missingPriceModels: prices.filter { $0.rates == .unknown }.map(\.model))
                }
                var inserted = 0
                var removed = 0
                let future = prices.filter { ($0.effectiveAt ?? midnight) > observation }
                let scheduled = try Row.fetchAll(db, sql: "SELECT model,tier,effective_at FROM prices WHERE source_url=? AND effective_at>?",
                                                 arguments: [ModelsDevPricesV2.sourceURL, observedTimestamp])
                for row in scheduled {
                    let model: String = row["model"], tier: String = row["tier"], effectiveAt: Double = row["effective_at"]
                    guard !future.contains(where: {
                        $0.model == model && $0.tier == tier && $0.effectiveAt?.timeIntervalSince1970 == effectiveAt
                    }) else { continue }
                    try db.execute(sql: "DELETE FROM prices WHERE model=? AND tier=? AND effective_at=?",
                                   arguments: [model, tier, effectiveAt])
                    removed += db.changesCount
                }
                for price in prices {
                    let effectiveAt = (price.effectiveAt ?? midnight).timeIntervalSince1970
                    let previous = try Self.modelPrice(db: db, model: price.model, date: price.date, tier: price.tier,
                                                       occurredAt: effectiveAt, useDefaults: false, allowEarlierEstimate: false)
                    if let previous, price.samePricing(as: previous),
                       effectiveAt <= observedTimestamp || previous.effectiveAt == price.effectiveAt { continue }
                    var values: [String: (any DatabaseValueConvertible)?] = [
                        "model": price.model, "date": price.date, "tier": price.tier, "effective_at": effectiveAt,
                        "long_context_threshold": price.longContextThreshold,
                        "context_rule": price.contextRule.rawValue, "source_url": price.source.url,
                        "is_bundled": price.source.isBundled, "combination_rule": price.source.combinationRule,
                        "combination_source": price.source.combinationSource
                    ]
                    for (prefix, rates) in [("", price.rates), ("long_", price.long)] {
                        values[prefix + "input_price"] = rates.input.map { NSDecimalNumber(decimal: $0).stringValue }
                        values[prefix + "output_price"] = rates.output.map { NSDecimalNumber(decimal: $0).stringValue }
                        values[prefix + "cache_read_price"] = rates.cacheRead.map { NSDecimalNumber(decimal: $0).stringValue }
                        values[prefix + "cache_write_price"] = rates.cacheWrite.map { NSDecimalNumber(decimal: $0).stringValue }
                    }
                    let columns = values.keys.sorted()
                    var arguments = StatementArguments(columns.map { values[$0] ?? nil })
                    arguments += [observedTimestamp]
                    let updates = columns.filter { !["model", "tier", "effective_at"].contains($0) }
                        .map { "\($0)=excluded.\($0)" }.joined(separator: ",")
                    try db.execute(sql: """
                        INSERT INTO prices (\(columns.joined(separator: ","))) VALUES (\(columns.map { _ in "?" }.joined(separator: ",")))
                        ON CONFLICT(model,tier,effective_at) DO UPDATE SET \(updates) WHERE prices.effective_at>?
                        """,
                                   arguments: arguments)
                    inserted += db.changesCount
                }
                try db.execute(sql: "INSERT INTO app_metadata(key, value) VALUES ('prices_last_success_date', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                               arguments: [date])
                try db.execute(sql: "INSERT INTO app_metadata(key, value) VALUES ('prices_last_success_source', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                               arguments: [ModelsDevPricesV2.sourceURL])
                if inserted > 0 || removed > 0 {
                    try db.execute(sql: "INSERT INTO app_metadata(key, value) VALUES ('pricing_rebuild_pending', 'true') ON CONFLICT(key) DO UPDATE SET value = 'true'")
                }
                return PriceSyncReport(date: date, alreadySynced: false, models: Set(prices.map(\.model)).count, insertedSnapshots: inserted,
                                       unsupportedContextModels: prices.filter { $0.contextRule == .unsupported && $0.rates != .unknown }.map(\.model),
                                           missingPriceModels: prices.filter { $0.rates == .unknown }.map(\.model))
            }
        }
    }

    static func modelPrice(db: Database, model: String, date: String, tier: String = "standard",
                           occurredAt: Double? = nil, useDefaults: Bool = true, allowEarlierEstimate: Bool = true) throws -> ModelPrice? {
        let instant = occurredAt ?? DateParsing.parseTimestamp(date + "T00:00:00Z")?.timeIntervalSince1970
        let applicable = try Row.fetchOne(db, sql: "SELECT * FROM prices WHERE model=? AND tier=? AND effective_at<=? ORDER BY effective_at DESC LIMIT 1",
                                          arguments: [model, tier, instant])
        // Preserve the existing earliest-snapshot estimate for pre-v2 daily snapshots.
        let row = try applicable ?? (allowEarlierEstimate ? Row.fetchOne(db, sql: """
            SELECT * FROM prices WHERE model=? AND tier=? AND source_url<>? ORDER BY effective_at LIMIT 1
            """, arguments: [model, tier, ModelsDevPricesV2.sourceURL]) : nil)
        let usageTime = instant.map(Date.init(timeIntervalSince1970:)) ?? .distantPast
        guard let row else { return useDefaults ? try BundledModelPrices.price(model: model, tier: tier, at: usageTime) : nil }
        guard let rule = ModelPrice.ContextRule(rawValue: row["context_rule"]) else { throw PriceError.invalidDocument }
        let source = PriceSource(isBundled: row["is_bundled"], url: row["source_url"],
                                 combinationRule: row["combination_rule"], combinationSource: row["combination_source"],
                                 contextRule: rule)
        func rates(_ prefix: String) -> PriceRates {
            func decimal(_ column: String) -> Decimal? {
                let text: String? = row[prefix + column]
                return text.flatMap { Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) }
            }
            return PriceRates(input: decimal("input_price"), output: decimal("output_price"),
                              cacheRead: decimal("cache_read_price"), cacheWrite: decimal("cache_write_price"))
        }
        let price = ModelPrice(model: row["model"], date: row["date"], tier: row["tier"], rates: rates(""),
                               long: rates("long_"), longContextThreshold: row["long_context_threshold"],
                               contextRule: source.contextRule, source: source,
                               effectiveAt: source.url == ModelsDevPricesV2.sourceURL ? Date(timeIntervalSince1970: row["effective_at"]) : nil)
        if useDefaults, let fallback = try BundledModelPrices.price(model: model, tier: tier, at: usageTime) {
            if price.rates == .unknown, price.long == .unknown { return fallback }
            if let cutover = fallback.effectiveAt?.timeIntervalSince1970, cutover > (row["effective_at"] as Double),
               try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM prices WHERE model=? AND tier=? AND source_url=?
                    AND combination_rule='source-tier-schedule')
                """, arguments: [model, tier, ModelsDevPricesV2.sourceURL]) != true {
                // An old pre-cutover snapshot must not suppress a newer published offline rate.
                return fallback
            }
        }
        return price
    }

    public func priceEntries(limit: Int = 100) throws -> [PriceEntry] {
        try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM prices ORDER BY effective_at DESC, model, tier LIMIT ?", arguments: [min(max(limit, 1), 10_000)])
                .map { row in
                    var rates: [String: String?] = [:]
                    for prefix in ["", "long_"] {
                        for component in ["input", "output", "cache_read", "cache_write"] {
                            let key = prefix + component + "_price"
                            let value: String? = row[key]
                            rates.updateValue(value, forKey: key)
                        }
                    }
                    return PriceEntry(model: row["model"], date: row["date"], tier: row["tier"], rates: rates, longContextThreshold: row["long_context_threshold"])
                }
        }
    }
}
