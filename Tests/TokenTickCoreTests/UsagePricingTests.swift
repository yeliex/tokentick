import Foundation
import Testing
@testable import TokenTickCore

struct UsagePricingTests {
    @Test func subscriptionAndAPIUseTheSamePublishedFastAndCacheRates() throws {
        let tokens = TokenUsage(inputTokens: 100, outputTokens: 5, cachedInputTokens: 10, cacheWriteInputTokens: 20,
                                reasoningOutputTokens: 0, totalTokens: 105)
        let price = Self.price(tier: "fast", rates: PriceRates(input: 23, output: 95, cacheRead: 2, cacheWrite: 25))
        let api = try UsagePricing.calculate(tokens: tokens, price: price)
        let subscription = try UsagePricing.calculate(tokens: tokens, price: price, applyLongContextRates: false)
        #expect(subscription.rates.input == 23 && subscription.rates.cacheWrite == 25)
        #expect(subscription.amount == api.amount && api.amount == 2_605_000)
    }

    @Test func fourModesChargeDisjointInputAndOutputComponents() throws {
        let price = try fixturePrice()
        let short = TokenUsage(inputTokens: 1_000, outputTokens: 100, cachedInputTokens: 600, cacheWriteInputTokens: 200,
                               reasoningOutputTokens: 80, totalTokens: 1_100)
        let normal = try UsagePricing.calculate(tokens: short, price: price)
        #expect(normal.inputAmount == 2_000_000)
        #expect(normal.outputAmount == 5_000_000)
        #expect(normal.cacheReadAmount == 600_000)
        #expect(normal.cacheWriteAmount == 2_500_000)
        #expect(normal.amount == 10_100_000)
        #expect(try UsagePricing.calculate(tokens: short, price: fixturePrice(tier: "fast")).amount == 20_200_000)
        let long = TokenUsage(inputTokens: 272_001, outputTokens: 100, cachedInputTokens: 100_000, cacheWriteInputTokens: 100_000,
                              reasoningOutputTokens: 80, totalTokens: 272_101)
        #expect(try UsagePricing.calculate(tokens: long, price: price).amount == 4_147_520_000)
        #expect(try UsagePricing.calculate(tokens: long, price: fixturePrice(tier: "fast")).amount == 8_295_040_000)
    }

    @Test(arguments: [271_999, 272_000, 272_001]) func thresholdIsStrictlyGreaterThan(input: Int64) throws {
        let tokens = TokenUsage(inputTokens: input, outputTokens: 0, cachedInputTokens: 0, cacheWriteInputTokens: 0,
                               reasoningOutputTokens: 0, totalTokens: input)
        let result = try UsagePricing.calculate(tokens: tokens, price: fixturePrice())
        #expect(result.isLongContext == (input > 272_000))
        #expect(result.rates.input == (input > 272_000 ? 20 : 10))
    }

    @Test func missingModeUsesStandardWhilePricesAndCountersRemainUnknown() throws {
        let tokens = TokenUsage(inputTokens: 1_000, outputTokens: 100, cachedInputTokens: 600, cacheWriteInputTokens: nil,
                               reasoningOutputTokens: nil, totalTokens: 1_100)
        let partial = try UsagePricing.calculate(tokens: tokens, price: fixturePrice())
        #expect(partial.inputAmount == nil)
        #expect(partial.outputAmount == 5_000_000)
        #expect(partial.cacheReadAmount == 600_000)
        #expect(partial.cacheWriteAmount == nil)
        #expect(partial.amount == nil)
        #expect(try UsagePricing.calculate(tokens: tokens, price: fixturePrice()).outputAmount == 5_000_000)
        #expect(try UsagePricing.calculate(tokens: tokens, price: nil).amount == nil)
        let zero = TokenUsage(inputTokens: 0, outputTokens: 0, cachedInputTokens: nil, cacheWriteInputTokens: nil,
                             reasoningOutputTokens: nil, totalTokens: 0)
        #expect(try UsagePricing.calculate(tokens: zero, price: nil).amount == 0)
    }

    @Test func missingNonzeroPricePreservesOtherAmounts() throws {
        let price = Self.price(rates: PriceRates(input: 10, output: 50, cacheRead: 1))
        let tokens = TokenUsage(inputTokens: 1_000, outputTokens: 100, cachedInputTokens: 600, cacheWriteInputTokens: 200,
                               reasoningOutputTokens: 80, totalTokens: 1_100)
        let result = try UsagePricing.calculate(tokens: tokens, price: price)
        #expect(result.inputAmount == 2_000_000)
        #expect(result.cacheWriteAmount == nil)
        #expect(result.amount == nil)
    }

    @Test func decimalPrecisionBankersRoundingAndOverflow() throws {
        #expect(try UsagePricing.amount(tokens: 1, rate: Decimal(string: "0.0015")) == 2)
        #expect(try UsagePricing.amount(tokens: 1, rate: Decimal(string: "0.0025")) == 2)
        #expect(try UsagePricing.amount(tokens: 9_007_199_254_740_993, rate: Decimal(string: "0.001")) == 9_007_199_254_740_993)
        #expect(try UsagePricing.amount(tokens: Int64.max, rate: Decimal(string: "0.001")) == Int64.max)
        #expect(throws: PriceError.self) { try UsagePricing.amount(tokens: Int64.max, rate: 1) }
    }

    @Test func impossibleCacheBreakdownIsRejected() throws {
        let tokens = TokenUsage(inputTokens: 100, outputTokens: 10, cachedInputTokens: 80, cacheWriteInputTokens: 30,
                               reasoningOutputTokens: 0, totalTokens: 110)
        #expect(throws: PriceError.self) { try UsagePricing.calculate(tokens: tokens, price: fixturePrice()) }
    }

    @Test func nonzeroUnknownTokensCannotBecomeAZeroCostRequest() throws {
        let tokens = TokenUsage(inputTokens: 0, outputTokens: 0, cachedInputTokens: nil, cacheWriteInputTokens: nil,
                               reasoningOutputTokens: nil, totalTokens: 10)
        #expect(throws: PriceError.self) { try UsagePricing.calculate(tokens: tokens, price: nil) }
    }

    static func price(model: String = "gpt-6-astra", date: String = "2026-09-09", tier: String = "standard",
                      rates: PriceRates, long: PriceRates = .unknown, threshold: Int64? = nil,
                      rule: ModelPrice.ContextRule = .uniform) -> ModelPrice {
        ModelPrice(model: model, date: date, tier: tier, rates: rates, long: long,
                   longContextThreshold: threshold, contextRule: rule,
                   source: PriceSource(url: ModelsDevPricesV2.sourceURL, combinationRule: nil, combinationSource: nil, contextRule: rule),
                   effectiveAt: DateParsing.parseTimestamp(date + "T00:00:00Z"))
    }

    static func prices(date: String = "2026-09-09", input: Decimal = 10, longInput: Decimal = 20) -> [ModelPrice] {
        [price(date: date, rates: PriceRates(input: input, output: 50, cacheRead: 1, cacheWrite: 12.5),
               long: PriceRates(input: longInput, output: 75, cacheRead: 2, cacheWrite: 25),
               threshold: 272_000, rule: .requestInputGreaterThan),
         price(date: date, tier: "fast", rates: PriceRates(input: input * 2, output: 100, cacheRead: 2, cacheWrite: 25),
               long: PriceRates(input: longInput * 2, output: 150, cacheRead: 4, cacheWrite: 50),
               threshold: 272_000, rule: .requestInputGreaterThan)]
    }

    private func fixturePrice(tier: String = "standard") throws -> ModelPrice {
        try #require(Self.prices().first { $0.tier == tier })
    }
}
