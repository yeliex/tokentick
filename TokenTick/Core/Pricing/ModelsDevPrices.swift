import Foundation

struct ModelsDevPrices {
    static let sourceURL = "https://models.dev/api.json"

    static func decode(_ data: Data, date: String) throws -> [ModelPrice] {
        guard let parsed = DateParsing.parseTimestamp(date + "T00:00:00Z"),
              parsed.formatted(.iso8601.year().month().day().dateSeparator(.dash)) == date else { throw PriceError.invalidDate }
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard !document.openai.models.isEmpty else { throw PriceError.invalidDocument }
        return try document.openai.models.sorted(by: { $0.key < $1.key }).flatMap { model, entry in
            guard entry.id == model else { throw PriceError.invalidDocument }
            let decoder = JSONDecoder(), encoder = JSONEncoder()
            func rates(_ raw: SourceJSON?) throws -> PriceRates {
                try raw.map { try decoder.decode(PriceRates.self, from: encoder.encode($0)).validated() } ?? .unknown
            }
            func context(_ cost: SourceJSON?) throws -> (PriceRates, Int64?, ModelPrice.ContextRule) {
                guard let cost else { return (.unknown, nil, .unsupported) }
                if let raw = cost["tiers"] {
                    let tiers = try decoder.decode([Tier].self, from: encoder.encode(raw))
                    if tiers.count == 1, let first = tiers.first, first.tier.type == "context", first.tier.size > 0 {
                        return (try rates(raw[0]), first.tier.size, .requestInputGreaterThan)
                    }
                    if !tiers.isEmpty || cost["context_over_200k"] != nil { return (.unknown, nil, .unsupported) }
                } else if cost["context_over_200k"] != nil { return (.unknown, nil, .unsupported) }
                return (.unknown, nil, .uniform)
            }
            let standard = try rates(entry.cost)
            let (long, threshold, rule) = try context(entry.cost)
            let source = PriceSource(url: sourceURL, cost: entry.cost ?? .null, experimental: entry.experimental,
                                     combinationRule: nil, combinationSource: nil, contextRule: rule)
            var result = [ModelPrice(model: model, date: date, tier: "standard", rates: standard, long: long,
                                     longContextThreshold: threshold, contextRule: rule, source: source)]
            if case .object(let modes) = entry.experimental?["modes"] {
                var seen: Set<String> = ["standard"]
                for (name, mode) in modes.sorted(by: { $0.key < $1.key }) {
                    guard let cost = mode["cost"], case .string(let rawTier) = mode["provider"]?["body"]?["service_tier"] else { continue }
                    let tier = CodexServiceTier.normalized(rawTier)
                    guard let tier, seen.insert(tier).inserted else { throw PriceError.invalidDocument }
                    let modeRates = try rates(cost)
                    let (explicitLong, explicitThreshold, explicitRule) = try context(cost)
                    let hasContext = cost["tiers"] != nil || cost["context_over_200k"] != nil
                    let modeLong = try hasContext ? explicitLong : modeRates.applyingContextRatio(base: standard, long: long)
                    let modeRule = hasContext ? explicitRule : rule
                    let proof = PriceSource(url: sourceURL, cost: entry.cost ?? .null, experimental: entry.experimental,
                        combinationRule: hasContext ? "explicit-mode-context:" + name : (rule == .requestInputGreaterThan ? "derived-component-context-ratio" : nil),
                        combinationSource: sourceURL, contextRule: modeRule)
                    result.append(ModelPrice(model: model, date: date, tier: tier, rates: modeRates, long: modeLong,
                        longContextThreshold: hasContext ? explicitThreshold : threshold, contextRule: modeRule, source: proof))
                }
            }
            return result
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
