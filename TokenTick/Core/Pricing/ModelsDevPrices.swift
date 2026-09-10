import Foundation

struct ModelsDevPrices {
    static let sourceURL = "https://models.dev/api.json"

    static func decode(_ data: Data, date: String) throws -> [ModelPrice] {
        guard let parsed = RolloutParser.parseDate(date + "T00:00:00Z"),
              parsed.formatted(.iso8601.year().month().day().dateSeparator(.dash)) == date else { throw PriceError.invalidDate }
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard !document.openai.models.isEmpty else { throw PriceError.invalidDocument }
        return try document.openai.models.sorted(by: { $0.key < $1.key }).map { model, entry in
            guard entry.id == model else { throw PriceError.invalidDocument }
            let decoder = JSONDecoder()
            let encoder = JSONEncoder()
            let cost = entry.cost ?? .null
            let standard = try entry.cost.map { try decoder.decode(PriceRates.self, from: encoder.encode($0)).validated() } ?? .unknown
            let rawFast = entry.experimental?["modes"]?["fast"]?["cost"]
            let fast = try rawFast.map { try decoder.decode(PriceRates.self, from: encoder.encode($0)).validated() } ?? .unknown
            var long = PriceRates.unknown
            var threshold: Int64?
            var contextRule = entry.cost == nil ? ModelPrice.ContextRule.unsupported : .uniform
            if let rawTiers = cost["tiers"] {
                let tiers = try decoder.decode([Tier].self, from: encoder.encode(rawTiers))
                if tiers.count == 1, let first = tiers.first, first.tier.type == "context", first.tier.size > 0 {
                    threshold = first.tier.size
                    long = try decoder.decode(PriceRates.self, from: encoder.encode(rawTiers[0])).validated()
                    contextRule = .requestInputGreaterThan
                } else if !tiers.isEmpty || cost["context_over_200k"] != nil { contextRule = .unsupported }
            } else if cost["context_over_200k"] != nil {
                contextRule = .unsupported
            }
            var fastLong = PriceRates.unknown
            var combinationRule: String?
            var combinationSource: String?
            // 仅按核验过的模型规则组合；其他模型和不符合来源倍率的费率不类推。
            let verified = ["gpt-6-astra", "gpt-5.6-sol", "gpt-5.6", "gpt-5.6-terra", "gpt-5.6-luna"]
            if verified.contains(model), threshold == 272_000, fast == standard.multiplied(by: 2),
               standard.input != nil, standard.output != nil {
                fastLong = try long.multiplied(by: 2).validated()
                combinationRule = "fast-times-applicable-rate-2; verified-2026-09-09"
                combinationSource = "https://developers.openai.com/api/docs/pricing#fast-mode"
            }
            let source = PriceSource(url: sourceURL, cost: cost, experimental: entry.experimental,
                                     combinationRule: combinationRule, combinationSource: combinationSource, contextRule: contextRule)
            return ModelPrice(model: model, date: date, standard: standard, fast: fast, long: long, fastLong: fastLong,
                              longContextThreshold: threshold, contextRule: contextRule, source: source)
        }
    }

    private struct Document: Decodable {
        let openai: Provider
        struct Provider: Decodable { let models: [String: Entry] }
        struct Entry: Decodable {
            let id: String
            let cost: SourceJSON?
            let experimental: SourceJSON?
        }
    }
    private struct Tier: Decodable {
        let tier: Boundary
        struct Boundary: Decodable {
            let type: String
            let size: Int64
        }
    }
}

private extension SourceJSON {
    subscript(_ index: Int) -> Self {
        guard case .array(let values) = self, values.indices.contains(index) else { return .null }
        return values[index]
    }
}
