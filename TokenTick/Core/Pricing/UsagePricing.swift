import Foundation

struct UsagePricing {
    struct Result {
        let rates: PriceRates
        let isLongContext: Bool?
        let inputAmount: Int64?
        let outputAmount: Int64?
        let cacheReadAmount: Int64?
        let cacheWriteAmount: Int64?
        let amount: Int64?
    }

    static func calculate(tokens: TokenUsage, price: ModelPrice?) throws -> Result {
        let reportedTotal = tokens.inputTokens.addingReportingOverflow(tokens.outputTokens)
        guard tokens.inputTokens >= 0, tokens.outputTokens >= 0, !reportedTotal.overflow,
              reportedTotal.partialValue == tokens.totalTokens else { throw PriceError.invalidUsage }
        let cacheRead = tokens.cachedInputTokens ?? (tokens.inputTokens == 0 ? 0 : nil)
        let cacheWrite = tokens.cacheWriteInputTokens ?? (tokens.inputTokens == 0 ? 0 : nil)
        if let cacheRead, cacheRead > tokens.inputTokens { throw PriceError.invalidUsage }
        if let cacheWrite, cacheWrite > tokens.inputTokens { throw PriceError.invalidUsage }
        let ordinaryInput: Int64?
        if let cacheRead, let cacheWrite {
            guard cacheRead <= tokens.inputTokens - cacheWrite else { throw PriceError.invalidUsage }
            ordinaryInput = tokens.inputTokens - cacheRead - cacheWrite
        } else { ordinaryInput = nil }
        let isLong: Bool? = if let price {
            switch price.contextRule {
            case .uniform: false
            case .requestInputGreaterThan: price.longContextThreshold.map { tokens.inputTokens > $0 }
            case .unsupported: nil
            }
        } else { nil }
        let rates: PriceRates
        if let price, let isLong {
            rates = isLong ? price.long : price.rates
        } else { rates = .unknown }
        let input = try amount(tokens: ordinaryInput, rate: rates.input)
        let output = try amount(tokens: tokens.outputTokens, rate: rates.output)
        let read = try amount(tokens: cacheRead, rate: rates.cacheRead)
        let write = try amount(tokens: cacheWrite, rate: rates.cacheWrite)
        var total: Int64?
        if let input, let output, let read, let write {
            var sum: Int64 = 0
            for component in [input, output, read, write] {
                let next = sum.addingReportingOverflow(component)
                guard !next.overflow else { throw PriceError.amountOverflow }
                sum = next.partialValue
            }
            total = sum
        }
        return Result(rates: rates, isLongContext: isLong, inputAmount: input, outputAmount: output,
                      cacheReadAmount: read, cacheWriteAmount: write, amount: total)
    }

    /// 美元／百万 tokens × tokens × 1000 = 纳美元；先进行十进制运算，再银行家舍入。
    static func amount(tokens: Int64?, rate: Decimal?) throws -> Int64? {
        guard let tokens else { return nil }
        if tokens == 0 { return 0 }
        guard let rate else { return nil }
        guard tokens > 0, rate >= 0, !rate.isNaN else { throw PriceError.invalidRate }
        var left = Decimal(tokens)
        var right = rate
        var product = Decimal()
        guard NSDecimalMultiply(&product, &left, &right, .bankers) == .noError else { throw PriceError.amountOverflow }
        var scale = Decimal(1_000)
        var nano = Decimal()
        guard NSDecimalMultiply(&nano, &product, &scale, .bankers) == .noError else { throw PriceError.amountOverflow }
        var rounded = Decimal()
        NSDecimalRound(&rounded, &nano, 0, .bankers)
        guard rounded >= 0, rounded <= Decimal(Int64.max) else { throw PriceError.amountOverflow }
        return NSDecimalNumber(decimal: rounded).int64Value
    }
}
