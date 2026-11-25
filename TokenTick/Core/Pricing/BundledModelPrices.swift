import CryptoKit
import Foundation

/// Keep a small fixed catalog; its verification date is not a historical effective date.
enum BundledModelPrices {
    static let data: Result<Data, any Error> = Result {
        guard let url = Bundle.module.url(forResource: "openai-default-prices", withExtension: "json") else {
            throw PriceError.invalidDocument
        }
        return try Data(contentsOf: url)
    }
    private static let catalog: Result<[String: [String: [ModelPrice]]], any Error> = Result {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(Document.self, from: data.get())
        var prices: [String: [String: [ModelPrice]]] = [:]
        for price in document.models {
            guard !price.model.isEmpty,
                  prices[price.model]?[price.tier]?.contains(where: { $0.effectiveAt == price.effectiveAt }) != true else {
                throw PriceError.invalidDocument
            }
            for rates in [price.rates, price.long] { _ = try rates.validated() }
            prices[price.model, default: [:]][price.tier, default: []].append(price)
        }
        return prices.mapValues { $0.mapValues { $0.sorted { ($0.effectiveAt ?? .distantPast) > ($1.effectiveAt ?? .distantPast) } } }
    }
    static func price(model: String, tier: String = "standard", at instant: Date = .now) throws -> ModelPrice? {
        let prices = try catalog.get()[model]
        // Auto-review is free regardless of the speed recorded alongside the check.
        return prices?[model == "codex-auto-review" ? "standard" : tier]?.first { ($0.effectiveAt ?? .distantPast) <= instant }
    }
    static func fingerprint() throws -> String {
        try SHA256.hash(data: data.get()).map { String(format: "%02x", $0) }.joined()
    }
    private struct Document: Decodable { let models: [ModelPrice] }
}
