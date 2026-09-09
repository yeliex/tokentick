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
    public let rates: [String: String?]
    public let longContextThreshold: Int64?

    private enum CodingKeys: String, CodingKey { case model, date, rates, longContextThreshold }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(model, forKey: .model)
        try values.encode(date, forKey: .date)
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
                    return PriceSyncReport(date: date, alreadySynced: true, models: prices.count, insertedSnapshots: 0,
                                           unsupportedContextModels: prices.filter { $0.contextRule == .unsupported && $0.standard != .unknown }.map(\.model),
                                           missingPriceModels: prices.filter { $0.standard == .unknown && $0.fast == .unknown }.map(\.model))
                }
                var inserted = 0
                for price in prices {
                    let previous = try Self.modelPrice(db: db, model: price.model, date: date)
                    if let previous, price.samePricing(as: previous) { continue }
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.sortedKeys]
                    var values: [String: (any DatabaseValueConvertible)?] = [
                        "model": price.model, "date": date, "long_context_threshold": price.longContextThreshold,
                        "source_json": String(decoding: try encoder.encode(price.source), as: UTF8.self)
                    ]
                    for (prefix, rates) in [("", price.standard), ("fast_", price.fast), ("long_", price.long), ("fast_long_", price.fastLong)] {
                        values[prefix + "input_price"] = rates.input.map { NSDecimalNumber(decimal: $0).stringValue }
                        values[prefix + "output_price"] = rates.output.map { NSDecimalNumber(decimal: $0).stringValue }
                        values[prefix + "cache_read_price"] = rates.cacheRead.map { NSDecimalNumber(decimal: $0).stringValue }
                        values[prefix + "cache_write_price"] = rates.cacheWrite.map { NSDecimalNumber(decimal: $0).stringValue }
                    }
                    let columns = values.keys.sorted()
                    let arguments = StatementArguments(columns.map { values[$0] ?? nil })
                    try db.execute(sql: "INSERT INTO prices (\(columns.joined(separator: ","))) VALUES (\(columns.map { _ in "?" }.joined(separator: ",")))",
                                   arguments: arguments)
                    inserted += 1
                }
                try db.execute(sql: "INSERT INTO app_metadata(key, value) VALUES ('prices_last_success_date', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                               arguments: [date])
                return PriceSyncReport(date: date, alreadySynced: false, models: prices.count, insertedSnapshots: inserted,
                                       unsupportedContextModels: prices.filter { $0.contextRule == .unsupported && $0.standard != .unknown }.map(\.model),
                                           missingPriceModels: prices.filter { $0.standard == .unknown && $0.fast == .unknown }.map(\.model))
            }
        }
    }

    static func modelPrice(db: Database, model: String, date: String) throws -> ModelPrice? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM prices WHERE model = ? AND date <= ? ORDER BY date DESC LIMIT 1",
                                        arguments: [model, date]) else { return nil }
        let json: String = row["source_json"]
        let source = try JSONDecoder().decode(PriceSource.self, from: Data(json.utf8))
        func rates(_ prefix: String) -> PriceRates {
            func decimal(_ column: String) -> Decimal? {
                let text: String? = row[prefix + column]
                return text.flatMap { Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) }
            }
            return PriceRates(input: decimal("input_price"), output: decimal("output_price"),
                              cacheRead: decimal("cache_read_price"), cacheWrite: decimal("cache_write_price"))
        }
        return ModelPrice(model: row["model"], date: row["date"], standard: rates(""), fast: rates("fast_"),
                          long: rates("long_"), fastLong: rates("fast_long_"), longContextThreshold: row["long_context_threshold"],
                          contextRule: source.contextRule, source: source)
    }

    public func priceEntries(limit: Int = 100) throws -> [PriceEntry] {
        try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM prices ORDER BY date DESC, model LIMIT ?", arguments: [min(max(limit, 1), 10_000)])
                .map { row in
                    var rates: [String: String?] = [:]
                    for prefix in ["", "fast_", "long_", "fast_long_"] {
                        for component in ["input", "output", "cache_read", "cache_write"] {
                            let key = prefix + component + "_price"
                            let value: String? = row[key]
                            rates.updateValue(value, forKey: key)
                        }
                    }
                    return PriceEntry(model: row["model"], date: row["date"], rates: rates, longContextThreshold: row["long_context_threshold"])
                }
        }
    }
}
