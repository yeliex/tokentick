import CryptoKit
import Foundation

/// 固定的小型价格目录；不加载请求历史，不把内置核验日冒充历史生效日。
enum BundledModelPrices {
    static let data: Result<Data, any Error> = Result {
        guard let url = Bundle.module.url(forResource: "openai-default-prices", withExtension: "json") else {
            throw PriceError.invalidDocument
        }
        return try Data(contentsOf: url)
    }
    private static let catalog: Result<[String: [String: ModelPrice]], any Error> = Result {
        let document = try JSONDecoder().decode(Document.self, from: data.get())
        var prices: [String: [String: ModelPrice]] = [:]
        for price in document.models {
            guard prices[price.model]?[price.tier] == nil, !price.model.isEmpty else { throw PriceError.invalidDocument }
            for rates in [price.rates, price.long] { _ = try rates.validated() }
            prices[price.model, default: [:]][price.tier] = price
        }
        return prices
    }
    static func price(model: String, tier: String = "standard") throws -> ModelPrice? { try catalog.get()[model]?[tier] }
    static func fingerprint() throws -> String {
        try SHA256.hash(data: data.get()).map { String(format: "%02x", $0) }.joined()
    }
    private struct Document: Decodable { let models: [ModelPrice] }
}
