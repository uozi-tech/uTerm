import XCTest
@testable import uTerm

final class OpenAISSEParserTests: XCTestCase {
    func testDeltaContentLineYieldsText() {
        var p = OpenAISSEParser()
        let line = #"data: {"choices":[{"delta":{"content":"Hello"}}]}"#
        XCTAssertEqual(p.parse(line: line), [.text("Hello")])
    }

    func testDoneSentinelYieldsEmpty() {
        var p = OpenAISSEParser()
        XCTAssertEqual(p.parse(line: "data: [DONE]"), [])
    }

    func testNonDataLineYieldsEmpty() {
        var p = OpenAISSEParser()
        XCTAssertEqual(p.parse(line: "event: foo"), [])
        XCTAssertEqual(p.parse(line: ""), [])
    }

    func testEmptyDeltaYieldsEmpty() {
        var p = OpenAISSEParser()
        XCTAssertEqual(p.parse(line: #"data: {"choices":[{"delta":{}}]}"#), [])
    }

    func testMissingChoicesYieldsEmpty() {
        var p = OpenAISSEParser()
        XCTAssertEqual(p.parse(line: #"data: {"foo":"bar"}"#), [])
    }

    func testRoleOnlyDeltaYieldsEmpty() {
        // OpenAI 流首个 delta 通常只含 role，无 content。
        var p = OpenAISSEParser()
        XCTAssertEqual(p.parse(line: #"data: {"choices":[{"delta":{"role":"assistant"}}]}"#), [])
    }

    func testMalformedJSONYieldsEmpty() {
        var p = OpenAISSEParser()
        XCTAssertEqual(p.parse(line: "data: not json"), [])
    }

    func testSequenceOfDeltas() {
        var p = OpenAISSEParser()
        let l1 = #"data: {"choices":[{"delta":{"content":"foo"}}]}"#
        let l2 = #"data: {"choices":[{"delta":{"content":"bar"}}]}"#
        XCTAssertEqual(p.parse(line: l1), [.text("foo")])
        XCTAssertEqual(p.parse(line: l2), [.text("bar")])
    }
}
