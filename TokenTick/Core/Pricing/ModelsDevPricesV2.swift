import Foundation

enum ModelsDevPricesV2 {
    static let sourceURL = "https://models.dev/experimental/v2.0/api.json"

    static func decode(_ data: Data, observedAt: Date) throws -> [ModelPrice] {
        let models = try JSONDecoder().decode(Document.self, from: data).openai.models
        var prices: [ModelPrice] = []
        for (model, entry) in models.sorted(by: { $0.key < $1.key }) {
            guard model == entry.id else { throw PriceError.invalidDocument }
            guard let cost = entry.cost, let text = cost.text, text.input?.price != nil, text.output?.price != nil,
                  [text.input?.unit, text.output?.unit].allSatisfy({ $0 == nil || $0 == "token" }) else { continue }
            let standard = try text.rates()
            func append(_ tier: String, _ rates: TextRates, _ factor: Decimal, at instant: Date, scheduled: Bool = false) throws {
                let combination = scheduled ? "source-tier-schedule" : (tier == "standard" ? nil : "source-tier-multiplier")
                let rule = PriceSource(url: sourceURL, combinationRule: combination,
                                       combinationSource: tier == "standard" ? nil : sourceURL, contextRule: rates.rule)
                prices.append(ModelPrice(model: model, date: instant.formatted(.iso8601.year().month().day().dateSeparator(.dash)),
                    tier: tier, rates: try rates.base.scaled(by: factor), long: try rates.long.scaled(by: factor),
                    longContextThreshold: rates.threshold, contextRule: rates.rule, source: rule, effectiveAt: instant))
            }
            try append("standard", standard, 1, at: observedAt)
            var dated: [Multiplier] = []
            for multiplier in cost.multipliers ?? [] {
                switch Set(multiplier.when.keys) {
                case ["service_tier"]:
                    guard let tier = multiplier.tier, tier != "standard", let factor = multiplier.textFactor else { continue }
                    try append(tier, standard, factor, at: observedAt)
                case ["service_tier", "date"]: dated.append(multiplier)
                default: continue
                }
            }
            // OpenAI publishes these date boundaries in Pacific time; catalog dates alone do not encode a time zone.
            if ["gpt-6.2-astra", "gpt-6.2-sol"].contains(model) {
                var activeFactor: Decimal?
                for multiplier in dated where multiplier.tier == "ultrafast" {
                    let lower = multiplier.when["date"]?["gte"]
                    let upper = multiplier.when["date"]?["lt"]
                    guard case .object(let condition) = multiplier.when["date"], condition.count == 1,
                          (lower == nil) != (upper == nil), let factor = multiplier.textFactor,
                          let start = pacificMidnight(lower?.string ?? entry.release_date) else { throw PriceError.invalidDocument }
                    let end = pacificMidnight(upper?.string)
                    guard upper == nil || (end.map { $0 > start } == true) else { throw PriceError.invalidDocument }
                    try append("ultrafast", standard, factor, at: start, scheduled: true)
                    if start <= observedAt, end.map({ observedAt < $0 }) ?? true {
                        guard activeFactor == nil else { throw PriceError.invalidDocument }
                        activeFactor = factor
                    }
                }
                if let activeFactor {
                    // A later catalog may change the base prices under an already effective tier rule.
                    try append("ultrafast", standard, activeFactor, at: observedAt)
                }
            }
        }
        guard !prices.isEmpty else { throw PriceError.invalidDocument }
        return prices.sorted { ($0.effectiveAt ?? observedAt) < ($1.effectiveAt ?? observedAt) }
    }

    private static func pacificMidnight(_ value: String?) -> Date? {
        guard let value, let zone = TimeZone(identifier: "America/Los_Angeles") else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: value), formatter.string(from: date) == value else { return nil }
        return date
    }

    private struct Document: Decodable {
        let openai: Provider
        struct Provider: Decodable { let models: [String: Model] }
        struct Model: Decodable {
            let id: String
            let release_date: String?
            let cost: Cost?
        }
    }

    private struct Cost: Decodable {
        let text: TextCost?
        let multipliers: [Multiplier]?
    }

    private struct Multiplier: Decodable {
        let when: [String: SourceJSON]
        let factor: SourceJSON

        var tier: String? { CodexServiceTier.normalized(when["service_tier"]?["equals"]?.string) }
        var textFactor: Decimal? {
            switch factor {
            case .number(let value): value
            case .object: factor["text"]?.decimal
            default: nil
            }
        }
    }

    private struct TextRates {
        let base: PriceRates
        var long: PriceRates = .unknown
        var threshold: Int64?
        var rule: ModelPrice.ContextRule = .uniform
    }

    private struct TextCost: Decodable {
        let input: Component?
        let output: Component?

        func rates() throws -> TextRates {
            let base = try PriceRates(input: input?.price, output: output?.price, cacheRead: input?.cache?.read,
                                      cacheWrite: input?.cache?.writePrice).validated()
            let inputOverrides = input?.overrides ?? []
            let outputOverrides = output?.overrides ?? []
            let overrides = inputOverrides + outputOverrides
            guard !overrides.isEmpty else { return TextRates(base: base) }
            let thresholds = Set(overrides.compactMap(\.threshold))
            guard overrides.allSatisfy({ $0.threshold != nil }), thresholds.count == 1,
                  let threshold = thresholds.first else { return TextRates(base: base, rule: .unsupported) }
            var long = base
            for change in inputOverrides {
                long.input = change.price ?? long.input
                long.cacheRead = change.cache?.read ?? long.cacheRead
                long.cacheWrite = change.cache?.writePrice ?? long.cacheWrite
            }
            for change in outputOverrides { long.output = change.price ?? long.output }
            return TextRates(base: base, long: try long.validated(), threshold: threshold, rule: .requestInputGreaterThan)
        }
    }

    private struct Component: Decodable {
        let unit: String?
        let price: Decimal?
        let cache: Cache?
        let overrides: [Override]?
    }

    private struct Override: Decodable {
        let when: [String: SourceJSON]
        let price: Decimal?
        let cache: Cache?

        var threshold: Int64? {
            guard Set(when.keys) == ["context"], case .object(let context) = when["context"], context.count == 1,
                  let exact = context["gt"]?.decimal, let value = Int64(NSDecimalNumber(decimal: exact).stringValue),
                  value > 0 else { return nil }
            return value
        }
    }

    private struct Cache: Decodable {
        let read: Decimal?
        let write: SourceJSON?

        var writePrice: Decimal? { write?.decimal ?? write?["30m"]?.decimal }
    }
}

private extension SourceJSON {
    var string: String? { if case .string(let value) = self { value } else { nil } }
    var decimal: Decimal? { if case .number(let value) = self { value } else { nil } }
}

private extension PriceRates {
    func scaled(by factor: Decimal) throws -> Self {
        guard factor >= 0, !factor.isNaN else { throw PriceError.invalidRate }
        return try Self(input: input.map { $0 * factor }, output: output.map { $0 * factor },
                        cacheRead: cacheRead.map { $0 * factor }, cacheWrite: cacheWrite.map { $0 * factor }).validated()
    }
}
