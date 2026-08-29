import AgentKit
import XCTest
@testable import uTerm

final class ChatMessageRecordToolCallTests: XCTestCase {
    func testRoundTripToolCalls() {
        let calls = [ToolCallState(id: "c1", name: "run_command", command: "ls",
                                   status: .done, output: "a\nb", exitCode: 0)]
        let rec = ChatMessageRecord(roleRaw: ChatMessage.Role.assistant.rawValue, text: "ok",
                                    toolCallsJSON: ChatMessageRecord.encode(calls))
        XCTAssertEqual(rec.asChatMessage.toolCalls, calls)
    }

    func testEmptyWhenNoColumn() {
        let rec = ChatMessageRecord(roleRaw: ChatMessage.Role.user.rawValue, text: "hi")
        XCTAssertTrue(rec.asChatMessage.toolCalls.isEmpty)
        XCTAssertEqual(rec.toolCallsJSON, "")   // 旧数据默认空串
    }
}
