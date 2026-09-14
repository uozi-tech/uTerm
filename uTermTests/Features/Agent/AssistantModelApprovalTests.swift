import AgentKit
import XCTest
@testable import uTerm

@MainActor
final class AssistantModelApprovalTests: XCTestCase {
    private func setup(_ command: String = "df -h", mode: AgentSafety = .auto,
                       response: ApprovalTestClient.Response = .approve,
                       additionalCommand: String? = nil) -> (AssistantModel, ApprovalTestClient, MockCommandExecutor) {
        let client = ApprovalTestClient(command: command, response: response, additionalCommand: additionalCommand)
        let model = AssistantModel(client: client,
            provider: AIProvider(name: "test", kind: .openai, baseURL: "https://example.com", model: "test"), apiKey: "test")
        let executor = MockCommandExecutor()
        model.executor = executor
        model.approvalMode = mode
        model.input = "检查服务器磁盘空间"
        return (model, client, executor)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw TestTimeout() }
            await Task.yield()
        }
    }
    private struct TestTimeout: Error {}

    func testReviewHasHardDeadline() async {
        let config = LLMRequestConfig(model: "test", baseURL: URL(string: "https://example.com")!, apiKey: "test")
        do {
            _ = try await reviewToolApproval(client: BlockingLLMClient(), config: config,
                                             system: "review", prompt: "test", timeout: .milliseconds(30))
            XCTFail("A silent reviewer must time out")
        } catch {
            XCTAssertTrue(error is LLMClientError)
        }
    }

    func testAIApprovalExecutesOnceAndContinuesWithoutToolsInReview() async throws {
        let (model, client, executor) = setup()
        await model.send(serverContext: "test server")
        try await waitUntil { model.state == .idle }
        XCTAssertEqual(executor.ran, ["df -h"])
        XCTAssertEqual(client.captured.reviews, 1)
        XCTAssertEqual(client.captured.reviewConfig?.tools.isEmpty, true)
        XCTAssertEqual(model.messages.first { !$0.toolCalls.isEmpty }?.toolCalls.first?.approvedByAI, true)
    }

    func testSensitiveCommandStaysPendingWithoutAIRequest() async throws {
        let (model, client, executor) = setup("rm -rf /tmp/example")
        await model.send(serverContext: "")
        try await waitUntil { model.reviewingToolCallID == nil }
        XCTAssertEqual(model.state, .awaitingApproval)
        XCTAssertEqual(client.captured.reviews, 0)
        XCTAssertTrue(executor.ran.isEmpty)
        XCTAssertNotNil(model.messages.last?.toolCalls.first?.approvalReason)
        await model.approveAndRun(id: "c1")
        XCTAssertEqual(executor.ran, ["rm -rf /tmp/example"])
    }

    func testConfirmModeDoesNotReviewOrExecute() async {
        let (model, client, executor) = setup(mode: .confirm)
        await model.send(serverContext: "")
        XCTAssertEqual(model.state, .awaitingApproval)
        XCTAssertEqual(client.captured.reviews, 0)
        XCTAssertTrue(executor.ran.isEmpty)
    }

    func testBatchStopsAtSensitiveCommandAfterApprovingSafeCommand() async throws {
        let (model, client, executor) = setup(additionalCommand: "systemctl restart nginx")
        await model.send(serverContext: "")
        try await waitUntil { model.messages.last?.toolCalls.last?.approvalReason != nil }
        XCTAssertEqual(executor.ran, ["df -h"])
        XCTAssertEqual(client.captured.reviews, 1)
        XCTAssertEqual(model.messages.last?.toolCalls.last?.status, .pending)
        XCTAssertEqual(model.state, .awaitingApproval)
    }

    func testInvalidDeniedAndToolCallingReviewerRequireHuman() async throws {
        for response in [ApprovalTestClient.Response.manual, .invalid, .tool] {
            let (model, _, executor) = setup(response: response)
            await model.send(serverContext: "")
            try await waitUntil { model.reviewingToolCallID == nil }
            XCTAssertEqual(model.state, .awaitingApproval)
            XCTAssertTrue(executor.ran.isEmpty)
            XCTAssertEqual(model.messages.last?.toolCalls.first?.approvedByAI, false)
        }
    }

    func testSessionChangeCancelsInFlightReview() async throws {
        let (model, client, executor) = setup(response: .blocked)
        await model.send(serverContext: "")
        try await waitUntil { client.captured.reviews == 1 }
        model.startNewSession()
        client.finishReview()
        for _ in 0..<30 { await Task.yield() }
        XCTAssertTrue(executor.ran.isEmpty)
        XCTAssertTrue(model.messages.isEmpty)
        XCTAssertNil(model.reviewingToolCallID)
    }

    func testConnectionChangeInvalidatesReview() async throws {
        let (model, client, originalExecutor) = setup(response: .blocked)
        await model.send(serverContext: "")
        try await waitUntil { client.captured.reviews == 1 }
        let replacement = MockCommandExecutor()
        model.executor = replacement
        client.finishReview()
        for _ in 0..<30 { await Task.yield() }
        XCTAssertTrue(originalExecutor.ran.isEmpty)
        XCTAssertTrue(replacement.ran.isEmpty)
        XCTAssertEqual(model.state, .awaitingApproval)
    }

    func testManualExecutionDuringReviewCannotExecuteTwice() async throws {
        let (model, client, executor) = setup(response: .blocked)
        await model.send(serverContext: "")
        try await waitUntil { client.captured.reviews == 1 }
        await model.approveAndRun(id: "c1")
        client.finishReview()
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(executor.ran, ["df -h"])
        XCTAssertEqual(model.state, .idle)
    }

    func testSwitchToManualInvalidatesReview() async throws {
        let (model, client, executor) = setup(response: .blocked)
        await model.send(serverContext: "")
        try await waitUntil { client.captured.reviews == 1 }
        model.approvalMode = .confirm
        client.finishReview()
        for _ in 0..<30 { await Task.yield() }
        XCTAssertTrue(executor.ran.isEmpty)
        XCTAssertEqual(model.state, .awaitingApproval)
    }

    func testStopCancelsReviewAndSkipsCommand() async throws {
        let (model, client, executor) = setup(response: .blocked)
        await model.send(serverContext: "")
        try await waitUntil { client.captured.reviews == 1 }
        model.stop()
        client.finishReview()
        for _ in 0..<30 { await Task.yield() }
        XCTAssertTrue(executor.ran.isEmpty)
        XCTAssertEqual(model.messages.last?.toolCalls.first?.status, .skipped)
        XCTAssertEqual(model.state, .idle)
        XCTAssertNil(model.reviewingToolCallID)
    }
}

private struct ApprovalTestClient: LLMClient {
    enum Response { case approve, manual, invalid, tool, blocked }
    final class Captured: @unchecked Sendable {
        var reviews = 0
        var mainCalls = 0
        var reviewConfig: LLMRequestConfig?
        var continuation: AsyncThrowingStream<LLMEvent, Error>.Continuation?
        var reply = ""
    }
    let command: String
    let response: Response
    let additionalCommand: String?
    let captured = Captured()

    func stream(messages: [ChatMessage], system: String, config: LLMRequestConfig) -> AsyncThrowingStream<LLMEvent, Error> {
        if system == AgentToolApproval.systemPrompt {
            captured.reviews += 1
            captured.reviewConfig = config
            let request = try! JSONDecoder().decode(AgentToolApproval.Request.self, from: Data(messages[0].text.utf8))
            let data = try! JSONSerialization.data(withJSONObject: ["requestID": request.id,
                "decision": response == .manual ? "manual" : "approve", "reason": "测试审批"])
            captured.reply = String(decoding: data, as: UTF8.self)
            return AsyncThrowingStream { continuation in
                if response == .blocked { captured.continuation = continuation; return }
                if response == .tool {
                    continuation.yield(.toolCall(LLMToolCall(id: "bad", name: "run_command", argumentsJSON: "{}")))
                } else {
                    continuation.yield(.text(response == .invalid ? "invalid" : captured.reply))
                }
                continuation.finish()
            }
        }
        captured.mainCalls += 1
        let first = captured.mainCalls == 1
        return AsyncThrowingStream { continuation in
            if first {
                let args = try! JSONSerialization.data(withJSONObject: ["command": command])
                continuation.yield(.toolCall(LLMToolCall(id: "c1", name: "run_command", argumentsJSON: String(decoding: args, as: UTF8.self))))
                if let additionalCommand {
                    let additionalArgs = try! JSONSerialization.data(withJSONObject: ["command": additionalCommand])
                    continuation.yield(.toolCall(LLMToolCall(id: "c2", name: "run_command", argumentsJSON: String(decoding: additionalArgs, as: UTF8.self))))
                }
            } else { continuation.yield(.text("已完成")) }
            continuation.finish()
        }
    }
    func finishReview() {
        captured.continuation?.yield(.text(captured.reply))
        captured.continuation?.finish()
    }
}
