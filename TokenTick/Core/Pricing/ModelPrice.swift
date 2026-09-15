import Foundation

struct PriceRates: Codable, Equatable, Sendable {
    var input: Decimal?
    var output: Decimal?
    var cacheRead: Decimal?
    var cacheWrite: Decimal?
    static let unknown = PriceRates()

    enum CodingKeys: String, CodingKey {
        case input, output
        case cacheRead = "cache_read"
        case cacheWrite = "cache_write"
    }

    /// 分项倍率独立计算；缺价和零分母不能靠其他分项补齐。
    func applyingContextRatio(base: Self, long: Self) throws -> Self {
        func derive(_ rate: Decimal?, _ base: Decimal?, _ long: Decimal?) throws -> Decimal? {
            guard let rate, let base, base > 0, let long else { return nil }
            var numerator = long, denominator = base, ratio = Decimal(), value = rate, result = Decimal()
            let division = NSDecimalDivide(&ratio, &numerator, &denominator, .bankers)
            guard division == .noError || division == .lossOfPrecision else { throw PriceError.invalidRate }
            let multiplication = NSDecimalMultiply(&result, &value, &ratio, .bankers)
            guard multiplication == .noError || multiplication == .lossOfPrecision else { throw PriceError.invalidRate }
            return result
        }
        return try Self(input: derive(input, base.input, long.input), output: derive(output, base.output, long.output),
                        cacheRead: derive(cacheRead, base.cacheRead, long.cacheRead),
                        cacheWrite: derive(cacheWrite, base.cacheWrite, long.cacheWrite)).validated()
    }

    func validated() throws -> Self {
        for price in [input, output, cacheRead, cacheWrite].compactMap({ $0 }) {
            guard !price.isNaN, price >= 0 else { throw PriceError.invalidRate }
        }
        return self
    }
}

struct ModelPrice: Codable, Equatable, Sendable {
    let model: String
    let date: String
    let tier: String
    let rates: PriceRates
    let long: PriceRates
    let longContextThreshold: Int64?
    let contextRule: ContextRule
    let source: PriceSource

    enum ContextRule: String, Codable { case uniform, requestInputGreaterThan, unsupported }

    /// 价格和规则决定是否需要新快照，来源描述不参与比较。
    func samePricing(as other: Self) -> Bool {
        tier == other.tier && rates == other.rates && long == other.long
            && longContextThreshold == other.longContextThreshold && contextRule == other.contextRule
            && source.combinationRule == other.source.combinationRule
    }
}

struct PriceSource: Codable, Equatable, Sendable {
    var isBundled: Bool? = nil
    let url: String
    let combinationRule: String?
    let combinationSource: String?
    let contextRule: ModelPrice.ContextRule
}

enum PriceError: Error, LocalizedError {
    case invalidRate, invalidDocument, invalidDate, amountOverflow, invalidUsage
    var errorDescription: String? {
        switch self {
        case .invalidRate: String(localized: "Model prices must be nonnegative decimal numbers.", bundle: .module)
        case .invalidDocument: String(localized: "The price response has no valid OpenAI model entries.", bundle: .module)
        case .invalidDate: String(localized: "Price dates must use a valid UTC YYYY-MM-DD format.", bundle: .module)
        case .amountOverflow: String(localized: "The cost exceeds the integer nanoUSD range. No approximate result was written.", bundle: .module)
        case .invalidUsage: String(localized: "Token totals or cache components are inconsistent. Cost cannot be calculated reliably.", bundle: .module)
        }
    }
}
