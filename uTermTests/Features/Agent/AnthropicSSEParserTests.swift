import XCTest
@testable import uTerm

final class AnthropicSSEParserTests: XCTestCase {
    func testTextDeltaLineYieldsText() {
        var parser = AnthropicSSEParser()
        let line = #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}"#
        XCTAssertEqual(parser.parse(line: line), [.text("Hello")])
    }

    func testEventLineYieldsEmpty() {
        var parser = AnthropicSSEParser()
        XCTAssertEqual(parser.parse(line: "event: content_block_delta"), [])
    }

    func testEmptyLineYieldsEmpty() {
        var parser = AnthropicSSEParser()
        XCTAssertEqual(parser.parse(line: ""), [])
    }

    func testNonDeltaDataLineYieldsEmpty() {
        var parser = AnthropicSSEParser()
        let line = #"data: {"type":"message_stop"}"#
        XCTAssertEqual(parser.parse(line: line), [])
    }

    func testPingAndUnknownEventsIgnored() {
        var parser = AnthropicSSEParser()
        XCTAssertEqual(parser.parse(line: #"data: {"type":"ping"}"#), [])
        XCTAssertEqual(parser.parse(line: #"data: {"type":"message_start","message":{}}"#), [])
    }

    func testSequenceOfDeltas() {
        var parser = AnthropicSSEParser()
        let l1 = #"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"foo"}}"#
        let l2 = #"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"bar"}}"#
        XCTAssertEqual(parser.parse(line: l1), [.text("foo")])
        XCTAssertEqual(parser.parse(line: l2), [.text("bar")])
    }

    func testMalformedDataLineYieldsEmpty() {
        var parser = AnthropicSSEParser()
        XCTAssertEqual(parser.parse(line: "data: not json"), [])
    }
}
