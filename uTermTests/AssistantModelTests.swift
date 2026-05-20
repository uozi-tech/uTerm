import XCTest
@testable import uTerm

@MainActor
final class AssistantModelTests: XCTestCase {
    func testSendAppendsUserAndAssistantMessages() async {
        let backend = MockAssistantBackend(deltas: ["Hi", " there"])
        let model = AssistantModel(backend: backend, apiKey: "sk-test")
        model.input = "hello"
        await model.send(serverContext: "server: cluster-main")
        XCTAssertEqual(model.messages.count, 2)
        XCTAssertEqual(model.messages[0].role, .user)
        XCTAssertEqual(model.messages[0].text, "hello")
        XCTAssertEqual(model.messages[1].role, .assistant)
    }

    func testStreamedDeltasConcatenateIntoAssistantMessage() async {
        let backend = MockAssistantBackend(deltas: ["Hi", " there"])
        let model = AssistantModel(backend: backend, apiKey: "sk-test")
        model.input = "hello"
        await model.send(serverContext: "")
        XCTAssertEqual(model.messages.last?.text, "Hi there")
        XCTAssertEqual(model.state, .idle)
    }

    func testInputIsClearedOnSend() async {
        let backend = MockAssistantBackend(deltas: ["x"])
        let model = AssistantModel(backend: backend, apiKey: "sk-test")
        model.input = "hello"
        await model.send(serverContext: "")
        XCTAssertEqual(model.input, "")
    }

    func testEmptyInputDoesNothing() async {
        let backend = MockAssistantBackend(deltas: ["x"])
        let model = AssistantModel(backend: backend, apiKey: "sk-test")
        model.input = "   "
        await model.send(serverContext: "")
        XCTAssertTrue(model.messages.isEmpty)
    }

    func testBackendErrorReachesFailed() async {
        let backend = MockAssistantBackend(deltas: [], failWith: ClaudeClientError.invalidResponse)
        let model = AssistantModel(backend: backend, apiKey: "sk-test")
        model.input = "hello"
        await model.send(serverContext: "")
        guard case .failed = model.state else { return XCTFail("应为 .failed") }
    }

    func testServerContextGoesIntoSystemPrompt() async {
        let backend = MockAssistantBackend(deltas: ["x"])
        let model = AssistantModel(backend: backend, apiKey: "sk-test")
        model.input = "hello"
        await model.send(serverContext: "server: cluster-main")
        XCTAssertTrue(backend.captured.system.contains("cluster-main"))
    }

    func testSecondSendIgnoredWhileStreaming() async {
        let model = AssistantModel(backend: BlockingAssistantBackend(), apiKey: "sk-test")
        model.input = "first"
        let task = Task { await model.send(serverContext: "") }
        while model.state != .streaming { await Task.yield() }
        model.input = "second"
        await model.send(serverContext: "")
        XCTAssertEqual(model.messages.count, 2)
        XCTAssertEqual(model.messages[0].text, "first")
        task.cancel()
        _ = await task.value
    }

    func testUnauthorizedErrorGivesKeyHint() async {
        let backend = MockAssistantBackend(
            deltas: [],
            failWith: ClaudeClientError.httpError(status: 401, body: "{}"))
        let model = AssistantModel(backend: backend, apiKey: "sk-test")
        model.input = "hello"
        await model.send(serverContext: "")
        guard case .failed(let message) = model.state else {
            return XCTFail("应为 .failed")
        }
        XCTAssertTrue(message.contains("密钥"))
    }

    func testBackendReceivesOnlyRealMessagesNotEmptyAssistant() async {
        let backend = MockAssistantBackend(deltas: ["x"])
        let model = AssistantModel(backend: backend, apiKey: "sk-test")
        model.input = "hello"
        await model.send(serverContext: "")
        XCTAssertEqual(backend.captured.messages.count, 1)
        XCTAssertEqual(backend.captured.messages[0].role, .user)
    }
}
