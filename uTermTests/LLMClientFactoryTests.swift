import XCTest
@testable import uTerm

@MainActor
final class LLMClientFactoryTests: XCTestCase {
    func testAnthropicKindReturnsAnthropicClient() {
        let p = AIProvider(name: "x", kind: .anthropic,
                            baseURL: "", model: "")
        let c = LLMClientFactory.make(for: p)
        XCTAssertTrue(c is AnthropicClient)
    }

    func testOpenAIKindReturnsOpenAIClient() {
        let p = AIProvider(name: "x", kind: .openai,
                            baseURL: "", model: "")
        let c = LLMClientFactory.make(for: p)
        XCTAssertTrue(c is OpenAIClient)
    }
}
