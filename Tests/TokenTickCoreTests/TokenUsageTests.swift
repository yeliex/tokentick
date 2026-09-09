import Foundation
import Testing
@testable import TokenTickCore

struct TokenUsageTests {
    @Test func missingBreakdownsRemainUnknown() throws {
        let data = Data(#"{"input_tokens":100,"output_tokens":20,"total_tokens":120}"#.utf8)
        let usage = try JSONDecoder().decode(TokenUsage.self, from: data)
        #expect(usage.cachedInputTokens == nil)
        #expect(usage.cacheWriteInputTokens == nil)
        #expect(usage.reasoningOutputTokens == nil)
        #expect(usage.totalTokens == 120)
    }

    @Test func breakdownsDoNotInflateTotal() throws {
        let data = Data(#"{"input_tokens":100,"cached_input_tokens":60,"cache_write_input_tokens":10,"output_tokens":20,"reasoning_output_tokens":12,"total_tokens":120}"#.utf8)
        let usage = try JSONDecoder().decode(TokenUsage.self, from: data)
        #expect(usage.totalTokens == 120)
        #expect(usage.cachedInputTokens == 60)
        #expect(usage.reasoningOutputTokens == 12)
    }

    @Test func negativeCountersAreRejected() {
        let data = Data(#"{"input_tokens":-1,"output_tokens":20,"total_tokens":19}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(TokenUsage.self, from: data) }
    }
}
