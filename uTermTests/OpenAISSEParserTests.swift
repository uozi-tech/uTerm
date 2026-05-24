import XCTest
@testable import uTerm

final class OpenAISSEParserTests: XCTestCase {
    func testDeltaContentLineYieldsText() {
        var p = OpenAISSEParser()
        let line = #"data: {"choices":[{"delta":{"content":"Hello"}}]}"#
        XCTAssertEqual(p.parse(line: line), "Hello")
    }

    func testDoneSentinelYieldsNil() {
        var p = OpenAISSEParser()
        XCTAssertNil(p.parse(line: "data: [DONE]"))
    }

    func testNonDataLineYieldsNil() {
        var p = OpenAISSEParser()
        XCTAssertNil(p.parse(line: "event: foo"))
        XCTAssertNil(p.parse(line: ""))
    }

    func testEmptyDeltaYieldsNil() {
        var p = OpenAISSEParser()
        XCTAssertNil(p.parse(line: #"data: {"choices":[{"delta":{}}]}"#))
    }

    func testMissingChoicesYieldsNil() {
        var p = OpenAISSEParser()
        XCTAssertNil(p.parse(line: #"data: {"foo":"bar"}"#))
    }

    func testRoleOnlyDeltaYieldsNil() {
        // OpenAI 流首个 delta 通常只含 role，无 content。
        var p = OpenAISSEParser()
        XCTAssertNil(p.parse(line: #"data: {"choices":[{"delta":{"role":"assistant"}}]}"#))
    }

    func testMalformedJSONYieldsNil() {
        var p = OpenAISSEParser()
        XCTAssertNil(p.parse(line: "data: not json"))
    }

    func testSequenceOfDeltas() {
        var p = OpenAISSEParser()
        let l1 = #"data: {"choices":[{"delta":{"content":"foo"}}]}"#
        let l2 = #"data: {"choices":[{"delta":{"content":"bar"}}]}"#
        XCTAssertEqual(p.parse(line: l1), "foo")
        XCTAssertEqual(p.parse(line: l2), "bar")
    }
}
