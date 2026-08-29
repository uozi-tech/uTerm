import XCTest
@testable import uTerm

final class ContextCompressorTests: XCTestCase {

    private func turn(_ index: Int, outputSize: Int) -> [ChatMessage] {
        [
            ChatMessage(role: .user, text: "问题 \(index)"),
            ChatMessage(role: .assistant, text: "第 \(index) 轮回答。", toolCalls: [
                ToolCallState(
                    id: "c\(index)", name: "run_command", command: "ls -la",
                    status: .done,
                    output: String(repeating: "x", count: outputSize), exitCode: 0
                ),
            ]),
        ]
    }

    func testUnderBudgetIsIdentity() {
        let messages = turn(1, outputSize: 100)
        XCTAssertEqual(
            ContextCompressor.compress(messages, policy: .init(tokenBudget: 10_000)),
            messages
        )
    }

    func testFoldsOldOutputsKeepsRecentVerbatim() throws {
        let messages = (1...5).flatMap { turn($0, outputSize: 9000) }
        var policy = ContextCompressor.Policy()
        policy.tokenBudget = 5_000
        policy.keptRecentMessages = 2
        policy.foldedOutputCap = 100
        let out = ContextCompressor.compress(messages, policy: policy)

        XCTAssertEqual(out.count, messages.count)
        // 最后一轮（窗口内）原文保留。
        XCTAssertEqual(Array(out.suffix(2)), Array(messages.suffix(2)))
        // 第一轮的命令输出被折叠并带提示。
        let output = try XCTUnwrap(out[1].toolCalls.first?.output)
        XCTAssertTrue(output.contains("已折叠"))
        XCTAssertTrue(output.utf8.count < 400)
        // 状态与退出码保留。
        XCTAssertEqual(out[1].toolCalls.first?.status, .done)
        XCTAssertEqual(out[1].toolCalls.first?.exitCode, 0)
        XCTAssertLessThanOrEqual(ContextCompressor.estimateTokens(out), policy.tokenBudget)
    }

    func testDropsOldestTurnsWithDigestWhenFoldingIsNotEnough() throws {
        let messages = (1...8).flatMap { turn($0, outputSize: 9000) }
        var policy = ContextCompressor.Policy()
        policy.tokenBudget = 3_000
        policy.keptRecentMessages = 2
        policy.foldedOutputCap = 3000
        let out = ContextCompressor.compress(messages, policy: policy)

        // 首条是摘要 user note，含最早请求与命令次数。
        XCTAssertEqual(out.first?.role, .user)
        let note = try XCTUnwrap(out.first?.text)
        XCTAssertTrue(note.contains("上下文压缩"))
        XCTAssertTrue(note.contains("问题 1"))
        XCTAssertTrue(note.contains("次命令"))

        // 摘要后第一条必须是 user（丢弃对齐轮边界）。
        XCTAssertEqual(out[1].role, .user)
        // 最近一轮原文保留。
        XCTAssertEqual(Array(out.suffix(2)), Array(messages.suffix(2)))
    }
}
