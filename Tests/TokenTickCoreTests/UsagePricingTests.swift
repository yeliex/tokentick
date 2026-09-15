import Foundation
import GRDB
import Testing
@testable import TokenTickCore

struct UsagePricingTests {
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
        let price = try fixturePrice(json: Self.document.replacingOccurrences(of: #""cache_write":12.5"#, with: #""unrelated":12.5"#))
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
        let json = Self.document.replacingOccurrences(of: #""input":10,"output""#, with: #""input":0.123456789123456789,"output""#)
        #expect(try fixturePrice(json: json).rates.input == Decimal(string: "0.123456789123456789"))
    }

    @Test func impossibleCacheBreakdownIsRejected() throws {
        let tokens = TokenUsage(inputTokens: 100, outputTokens: 10, cachedInputTokens: 80, cacheWriteInputTokens: 30,
                               reasoningOutputTokens: 0, totalTokens: 110)
        #expect(throws: PriceError.self) { try UsagePricing.calculate(tokens: tokens, price: fixturePrice()) }
    }

    @Test func unlistedModelsUseComponentRatioWithoutGuessingLegacyThreshold() throws {
        let json = Self.document.replacingOccurrences(of: "gpt-6-astra", with: "future-model")
        let price = try fixturePrice(json: json, tier: "fast")
        #expect(price.long.input == 40)
        #expect(price.long.output == 150)
        #expect(price.rates.input == 20)
        let legacy = #"{"openai":{"models":{"m":{"id":"m","cost":{"input":1,"output":2,"context_over_200k":{"input":3}}}}}}"#
        #expect(try fixturePrice(json: legacy).contextRule == .unsupported)
        #expect(try fixturePrice(json: legacy.replacingOccurrences(of: #""context_over_200k""#, with: #""tiers":[],"context_over_200k""#)).contextRule == .unsupported)
    }

    @Test func multipleTiersRemainUnsupportedWithoutSilentlyChoosingOne() throws {
        let json = #"{"openai":{"models":{"m":{"id":"m","cost":{"input":1,"output":2,"tiers":[{"tier":{"type":"context","size":100},"input":2},{"tier":{"type":"context","size":200},"input":3}]}}}}}"#
        let price = try fixturePrice(json: json)
        #expect(price.contextRule == .unsupported)
        #expect(price.long == .unknown)
    }

    @Test func sourceValidationDoesNotAcceptNegativePricesOrWrongProvider() throws {
        #expect(throws: (any Error).self) { try fixturePrice(json: Self.document.replacingOccurrences(of: #""input":10"#, with: #""input":-10"#)) }
        #expect(throws: (any Error).self) { try fixturePrice(json: Self.document.replacingOccurrences(of: "openai", with: "other-provider")) }
        #expect(throws: (any Error).self) { try ModelsDevPrices.decode(Data(Self.document.utf8), date: "2026-02-30") }
    }

    @Test func modelsWithoutTokenPricesDoNotInvalidateTheProviderResponse() throws {
        let json = #"{"openai":{"models":{"image":{"id":"image"},"text":{"id":"text","cost":{"input":1,"output":2}}}}}"#
        let prices = try ModelsDevPrices.decode(Data(json.utf8), date: "2026-09-09")
        #expect(prices.count == 2)
        #expect(prices.first?.model == "image")
        #expect(prices.first?.rates == .unknown)
        #expect(prices.last?.rates.input == 1)
    }

    @Test func nonzeroUnknownTokensCannotBecomeAZeroCostRequest() throws {
        let tokens = TokenUsage(inputTokens: 0, outputTokens: 0, cachedInputTokens: nil, cacheWriteInputTokens: nil,
                               reasoningOutputTokens: nil, totalTokens: 10)
        #expect(throws: PriceError.self) { try UsagePricing.calculate(tokens: tokens, price: nil) }
    }

    @Test func componentRatioPreservesMissingAndZeroBaseAndExplicitContextWins() throws {
        let rates = try PriceRates(input: 12.5, output: 75, cacheRead: 2, cacheWrite: 4)
            .applyingContextRatio(base: PriceRates(input: 5, output: 30, cacheRead: 0),
                                  long: PriceRates(input: 10, output: 45, cacheRead: 2, cacheWrite: 8))
        #expect(rates.input == 25 && rates.output == Decimal(string: "112.5"))
        #expect(rates.cacheRead == nil && rates.cacheWrite == nil)
        let json = Self.document.replacingOccurrences(of: #""input":20,"output":100,"cache_read":2,"cache_write":25"#,
            with: #""input":20,"output":100,"cache_read":2,"cache_write":25,"tiers":[{"tier":{"type":"context","size":300000},"input":33,"output":120,"cache_read":3,"cache_write":40}]"#)
        let explicit = try fixturePrice(json: json, tier: "fast")
        #expect(explicit.long.input == 33 && explicit.long.output == 120)
        #expect(explicit.longContextThreshold == 300_000)
        #expect(explicit.source.combinationRule == "explicit-mode-context:fast")
    }

    static let document = #"""
    {"openai":{"models":{"gpt-6-astra":{"id":"gpt-6-astra","name":"Display titles do not affect price comparison",
      "cost":{"input":10,"output":50,"cache_read":1,"cache_write":12.5,
        "tiers":[{"tier":{"type":"context","size":272000},"input":20,"output":75,"cache_read":2,"cache_write":25}]},
      "experimental":{"modes":{"fast":{"cost":{"input":20,"output":100,"cache_read":2,"cache_write":25},"provider":{"body":{"service_tier":"priority"}}}}}
    }}}}
    """#

    func fixturePrice(json: String = Self.document, date: String = "2026-09-09", tier: String = "standard") throws -> ModelPrice {
        let prices = try ModelsDevPrices.decode(Data(json.utf8), date: date)
        return try #require(prices.first { $0.tier == tier })
    }
}
