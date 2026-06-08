import XCTest
@testable import uTerm

@MainActor
final class AssistantModelToolLoopTests: XCTestCase {
    private func provider() -> AIProvider {
        AIProvider(name: "t", kind: .openai, baseURL: "https://x", model: "m")
    }

    // MARK: - Task 13: 流式工具调用 → 待确认

    func testToolCallEntersAwaitingApproval() async {
        let client = MockLLMClient(events: [
            .text("我来执行"),
            .toolCall(LLMToolCall(id: "c1", name: "run_command",
                                  argumentsJSON: #"{"command":"ls"}"#)),
        ])
        let model = AssistantModel(client: client, provider: provider(), apiKey: "k")
        model.executor = MockCommandExecutor()
        model.input = "列目录"
        await model.send(serverContext: "")
        XCTAssertEqual(model.state, .awaitingApproval)
        let calls = model.messages.last?.toolCalls ?? []
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.command, "ls")
        XCTAssertEqual(calls.first?.status, .pending)
    }

    func testNoExecutorOmitsToolsAndStaysIdle() async {
        let client = MockLLMClient(events: [.text("纯文本回答")])
        let model = AssistantModel(client: client, provider: provider(), apiKey: "k")
        // 不注入 executor。
        model.input = "你好"
        await model.send(serverContext: "")
        XCTAssertEqual(model.state, .idle)
        XCTAssertEqual(client.captured.config?.tools.isEmpty, true)
        XCTAssertEqual(model.messages.last?.text, "纯文本回答")
    }

    // MARK: - Task 14: 批准 / 跳过 / 续轮

    func testApproveRunsExecutesFeedsResultAndContinues() async {
        let client = MockLLMClient(scripts: [
            [.toolCall(LLMToolCall(id: "c1", name: "run_command",
                                   argumentsJSON: #"{"command":"ls"}"#))],
            [.text("结果是 a, b")],   // 第二轮：模型读到工具结果后的续答
        ])
        let exec = MockCommandExecutor()
        exec.results["ls"] = CommandResult(output: "a\nb", exitCode: 0)
        let model = AssistantModel(client: client, provider: provider(), apiKey: "k")
        model.executor = exec
        model.input = "列目录"
        await model.send(serverContext: "")
        XCTAssertEqual(model.state, .awaitingApproval)

        await model.approveAndRun(id: "c1")
        XCTAssertEqual(exec.ran, ["ls"])
        let done = model.messages.first { !$0.toolCalls.isEmpty }?.toolCalls.first
        XCTAssertEqual(done?.status, .done)
        XCTAssertEqual(done?.output, "a\nb")
        XCTAssertEqual(done?.exitCode, 0)
        XCTAssertEqual(model.messages.last?.text, "结果是 a, b")
        XCTAssertEqual(model.state, .idle)
    }

    func testApproveIgnoresSecondApprovalWhileCommandIsRunning() async {
        let client = MockLLMClient(scripts: [
            [.toolCall(LLMToolCall(id: "c1", name: "run_command",
                                   argumentsJSON: #"{"command":"ls"}"#))],
            [.text("结果已读取")],
            [.text("不应出现第二轮")],
        ])
        let exec = DelayedCommandExecutor()
        let model = AssistantModel(client: client, provider: provider(), apiKey: "k")
        model.executor = exec
        model.input = "列目录"
        await model.send(serverContext: "")
        XCTAssertEqual(model.state, .awaitingApproval)

        async let first: Void = model.approveAndRun(id: "c1")
        await Task.yield()
        async let second: Void = model.approveAndRun(id: "c1")
        _ = await (first, second)

        let ranCommands = await exec.ranCommands()
        XCTAssertEqual(ranCommands, ["ls"])
        XCTAssertEqual(client.captured.callCount, 2)
        XCTAssertEqual(model.messages.last?.text, "结果已读取")
    }

    func testSkipFeedsPlaceholderAndContinues() async {
        let client = MockLLMClient(scripts: [
            [.toolCall(LLMToolCall(id: "c1", name: "run_command",
                                   argumentsJSON: #"{"command":"rm -rf /"}"#))],
            [.text("好的，已跳过")],
        ])
        let model = AssistantModel(client: client, provider: provider(), apiKey: "k")
        model.executor = MockCommandExecutor()
        model.input = "删了它"
        await model.send(serverContext: "")
        await model.skip(id: "c1")
        let s = model.messages.first { !$0.toolCalls.isEmpty }?.toolCalls.first
        XCTAssertEqual(s?.status, .skipped)
        XCTAssertEqual(model.messages.last?.text, "好的，已跳过")
        XCTAssertEqual(model.state, .idle)
    }

    func testExecutorErrorMarksFailedAndContinues() async {
        struct Boom: Error, LocalizedError { var errorDescription: String? { "炸了" } }
        let client = MockLLMClient(scripts: [
            [.toolCall(LLMToolCall(id: "c1", name: "run_command",
                                   argumentsJSON: #"{"command":"oops"}"#))],
            [.text("命令失败了")],
        ])
        let exec = MockCommandExecutor()
        exec.error = Boom()
        let model = AssistantModel(client: client, provider: provider(), apiKey: "k")
        model.executor = exec
        model.input = "跑个会失败的"
        await model.send(serverContext: "")

        await model.approveAndRun(id: "c1")
        let failed = model.messages.first { !$0.toolCalls.isEmpty }?.toolCalls.first
        XCTAssertEqual(failed?.status, .failed)
        XCTAssertEqual(failed?.output, "炸了")
        XCTAssertEqual(model.messages.last?.text, "命令失败了")
        XCTAssertEqual(model.state, .idle)
    }

    func testContinuationCarriesResolvedToolCallsToProvider() async {
        let client = MockLLMClient(scripts: [
            [.toolCall(LLMToolCall(id: "c1", name: "run_command",
                                   argumentsJSON: #"{"command":"ls"}"#))],
            [.text("done")],
        ])
        let exec = MockCommandExecutor()
        exec.results["ls"] = CommandResult(output: "a", exitCode: 0)
        let model = AssistantModel(client: client, provider: provider(), apiKey: "k")
        model.executor = exec
        model.input = "列目录"
        await model.send(serverContext: "")
        await model.approveAndRun(id: "c1")

        // 续轮发给 provider 的会话里应包含已完成结果的 assistant 工具调用消息。
        let sent = client.captured.messages
        let toolMsg = sent.first { !$0.toolCalls.isEmpty }
        XCTAssertEqual(toolMsg?.toolCalls.first?.status, .done)
        XCTAssertEqual(toolMsg?.toolCalls.first?.output, "a")
    }

    // MARK: - 队列 × 工具循环

    func testQueuedMessageDispatchesAfterToolLoopResolves() async {
        let client = MockLLMClient(scripts: [
            [.toolCall(LLMToolCall(id: "c1", name: "run_command",
                                   argumentsJSON: #"{"command":"ls"}"#))],
            [.text("tool done")],          // 工具结果后的续答
            [.text("answer to queued")],   // 队列消息那一轮
        ])
        let exec = MockCommandExecutor()
        exec.results["ls"] = CommandResult(output: "a", exitCode: 0)
        let model = AssistantModel(client: client, provider: provider(), apiKey: "k")
        model.executor = exec
        model.input = "列目录"
        await model.send(serverContext: "")
        XCTAssertEqual(model.state, .awaitingApproval)

        // 待批准期间提交 → 入队，不立刻发。
        model.input = "再看看磁盘"
        await model.submit(serverContext: "")
        XCTAssertEqual(model.queuedMessages.map(\.text), ["再看看磁盘"])

        // 批准 → 工具续轮结算回 idle → 自动冲队列。
        await model.approveAndRun(id: "c1")
        XCTAssertTrue(model.queuedMessages.isEmpty)
        XCTAssertEqual(model.messages.last?.text, "answer to queued")
        XCTAssertNotNil(model.messages.first { $0.role == .user && $0.text == "再看看磁盘" })
        XCTAssertEqual(model.state, .idle)
    }

    // MARK: - FIX #28: 流式期间不可批准/跳过

    /// 流式仍在飞行（state == .streaming，但卡片已渲染成 pending）时，approveAndRun
    /// 必须被状态门禁挡住：不执行命令、不重入第二轮 streamAssistantTurn。
    func testApproveIgnoredWhileStreaming() async {
        let client = ToolThenBlockingLLMClient(
            firstTurn: [.toolCall(LLMToolCall(id: "c1", name: "run_command",
                                              argumentsJSON: #"{"command":"ls"}"#))])
        let exec = MockCommandExecutor()
        let model = AssistantModel(client: client, provider: provider(), apiKey: "k")
        model.executor = exec
        model.input = "列目录"

        // 不 await send：流永不结束，模型停在 .streaming。
        let send = Task { await model.send(serverContext: "") }
        // 让流先 yield 出 toolCall 并把模型推进 .streaming。
        while model.state != .streaming || (model.messages.last?.toolCalls.isEmpty ?? true) {
            await Task.yield()
        }
        XCTAssertEqual(model.state, .streaming)
        XCTAssertEqual(model.messages.last?.toolCalls.first?.status, .pending)

        // 流式期间点「运行」→ 被门禁挡住：命令未执行，状态仍 .streaming。
        await model.approveAndRun(id: "c1")
        XCTAssertTrue(exec.ran.isEmpty)
        XCTAssertEqual(model.state, .streaming)
        XCTAssertEqual(model.messages.last?.toolCalls.first?.status, .pending)
        // 同理「跳过」也被挡。
        await model.skip(id: "c1")
        XCTAssertEqual(model.messages.last?.toolCalls.first?.status, .pending)

        send.cancel()
        _ = await send.value
    }
}

/// 第一轮先 yield 出预设事件，然后永不结束（钉在 .streaming，直到流被取消）。
/// 用于验证流式期间 approveAndRun/skip 被门禁挡住。
private struct ToolThenBlockingLLMClient: LLMClient {
    let firstTurn: [LLMEvent]

    func stream(messages: [ChatMessage], system: String,
                config: LLMRequestConfig) -> AsyncThrowingStream<LLMEvent, Error> {
        let firstTurn = firstTurn
        return AsyncThrowingStream { continuation in
            let task = Task {
                for e in firstTurn { continuation.yield(e) }
                try? await Task.sleep(for: .seconds(60))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private actor DelayedCommandExecutor: CommandExecutor {
    private var ran: [String] = []

    func run(_ command: String) async throws -> CommandResult {
        ran.append(command)
        try? await Task.sleep(nanoseconds: 50_000_000)
        return CommandResult(output: "ok", exitCode: 0)
    }

    func ranCommands() -> [String] {
        ran
    }
}
