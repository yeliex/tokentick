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
            try String.fetchOne(db, sql: "SELECT value FROM app_metadata WHERE key = 'prices_last_success_date'") == date
        }
    }

    func savePrices(_ prices: [ModelPrice], date: String) throws -> PriceSyncReport {
        try FileWriteLock(url: databaseURL.appendingPathExtension("write.lock")).withLock {
            try pool.write { db in
                if try String.fetchOne(db, sql: "SELECT value FROM app_metadata WHERE key = 'prices_last_success_date'") == date {
                    return PriceSyncReport(date: date, alreadySynced: true, models: Set(prices.map(\.model)).count, insertedSnapshots: 0,
                                           unsupportedContextModels: prices.filter { $0.contextRule == .unsupported && $0.rates != .unknown }.map(\.model),
                                           missingPriceModels: prices.filter { $0.rates == .unknown }.map(\.model))
                }
                var inserted = 0
                for price in prices {
                    let previous = try Self.modelPrice(db: db, model: price.model, date: date, tier: price.tier, useDefaults: false)
                    if let previous, price.samePricing(as: previous) { continue }
                    var values: [String: (any DatabaseValueConvertible)?] = [
                        "model": price.model, "date": date, "tier": price.tier, "long_context_threshold": price.longContextThreshold,
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
                    let arguments = StatementArguments(columns.map { values[$0] ?? nil })
                    let updates = columns.filter { !["model", "date", "tier"].contains($0) }.map { "\($0)=excluded.\($0)" }.joined(separator: ",")
                    // New rules may replace a same-day price row; intraday versions are not modeled.
                    try db.execute(sql: "INSERT INTO prices (\(columns.joined(separator: ","))) VALUES (\(columns.map { _ in "?" }.joined(separator: ","))) ON CONFLICT(model,date,tier) DO UPDATE SET \(updates)",
                                   arguments: arguments)
                    inserted += 1
                }
                try db.execute(sql: "INSERT INTO app_metadata(key, value) VALUES ('prices_last_success_date', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                               arguments: [date])
                if inserted > 0 {
                    try db.execute(sql: "INSERT INTO app_metadata(key, value) VALUES ('pricing_rebuild_pending', 'true') ON CONFLICT(key) DO UPDATE SET value = 'true'")
                }
                return PriceSyncReport(date: date, alreadySynced: false, models: Set(prices.map(\.model)).count, insertedSnapshots: inserted,
                                       unsupportedContextModels: prices.filter { $0.contextRule == .unsupported && $0.rates != .unknown }.map(\.model),
                                           missingPriceModels: prices.filter { $0.rates == .unknown }.map(\.model))
            }
        }
    }

    static func modelPrice(db: Database, model: String, date: String, tier: String = "standard", useDefaults: Bool = true) throws -> ModelPrice? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM prices WHERE model = ? AND tier = ? AND date = COALESCE((SELECT MAX(date) FROM prices WHERE model = ? AND tier = ? AND date <= ?), (SELECT MIN(date) FROM prices WHERE model = ? AND tier = ?))",
                                        arguments: [model, tier, model, tier, date, model, tier]) else { return useDefaults ? try BundledModelPrices.price(model: model, tier: tier) : nil }
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
                               contextRule: source.contextRule, source: source)
        if useDefaults, price.rates == .unknown, price.long == .unknown,
           let fallback = try BundledModelPrices.price(model: model, tier: tier) { return fallback }
        return price
    }

    public func priceEntries(limit: Int = 100) throws -> [PriceEntry] {
        try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM prices ORDER BY date DESC, model, tier LIMIT ?", arguments: [min(max(limit, 1), 10_000)])
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
