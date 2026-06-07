import XCTest
@testable import uTerm

final class ToolSpecTests: XCTestCase {
    func testRunCommandOpenAIShape() throws {
        let json = ToolSpec.runCommand.openAIJSON()
        XCTAssertEqual(json["type"] as? String, "function")
        let fn = json["function"] as? [String: Any]
        XCTAssertEqual(fn?["name"] as? String, "run_command")
        let params = fn?["parameters"] as? [String: Any]
        XCTAssertEqual(params?["type"] as? String, "object")
        let props = params?["properties"] as? [String: Any]
        XCTAssertNotNil(props?["command"])
        XCTAssertEqual(params?["required"] as? [String], ["command"])
    }

    func testRunCommandAnthropicShape() throws {
        let json = ToolSpec.runCommand.anthropicJSON()
        XCTAssertEqual(json["name"] as? String, "run_command")
        let schema = json["input_schema"] as? [String: Any]
        XCTAssertEqual(schema?["type"] as? String, "object")
        let props = schema?["properties"] as? [String: Any]
        XCTAssertNotNil(props?["command"])
        XCTAssertEqual(schema?["required"] as? [String], ["command"])
    }
}
