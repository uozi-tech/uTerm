import AgentKit
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

    func testEmptySuccessfulStreamBecomesExplicitFailure() async {
        let client = MockLLMClient(events: [])
        let model = AssistantModel(client: client, provider: provider(), apiKey: "k")
        model.input = "你好"

        await model.send(serverContext: "")

        XCTAssertEqual(model.state, .failed("模型未返回任何内容"))
        XCTAssertEqual(model.messages.last?.text, "[错误：模型未返回任何内容]")
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

    func testApproveNotifiesWorkspaceAfterCommandAttempt() async {
        let client = MockLLMClient(scripts: [
            [.toolCall(LLMToolCall(id: "c1", name: "run_command",
                                   argumentsJSON: #"{"command":"sed -i s/a/b/ file"}"#))],
            [.text("已更新")],
        ])
        let exec = MockCommandExecutor()
        exec.results["sed -i s/a/b/ file"] = CommandResult(output: "", exitCode: 0)
        let model = AssistantModel(client: client, provider: provider(), apiKey: "k")
        model.executor = exec
        var refreshCount = 0
        model.onCommandExecutionFinished = { refreshCount += 1 }
        model.input = "修改文件"
        await model.send(serverContext: "")

        await model.approveAndRun(id: "c1")

        XCTAssertEqual(refreshCount, 1)
    }

    func testExecutorErrorStillNotifiesWorkspaceBecauseRemoteMayHavePartiallyWritten() async {
        struct Boom: Error {}
        let client = MockLLMClient(scripts: [
            [.toolCall(LLMToolCall(id: "c1", name: "run_command",
                                   argumentsJSON: #"{"command":"write then disconnect"}"#))],
            [.text("连接已中断")],
        ])
        let exec = MockCommandExecutor()
        exec.error = Boom()
        let model = AssistantModel(client: client, provider: provider(), apiKey: "k")
        model.executor = exec
        var refreshCount = 0
        model.onCommandExecutionFinished = { refreshCount += 1 }
        model.input = "执行"
        await model.send(serverContext: "")

        await model.approveAndRun(id: "c1")

        XCTAssertEqual(refreshCount, 1)
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

    // MARK: - 立即发送（下一步送达，不打断）

    private func toolLoopModel(_ client: MockLLMClient) -> AssistantModel {
        let exec = MockCommandExecutor()
        exec.results["ls"] = CommandResult(output: "a", exitCode: 0)
        let model = AssistantModel(client: client, provider: provider(), apiKey: "k")
        model.executor = exec
        return model
    }

    /// 工具结果出来后的那次续轮请求里就带上这条消息 —— 没有另开一轮，也没有取消过什么。
    func testNextStepMessageJoinsTheToolContinuation() async {
        let client = MockLLMClient(scripts: [
            [.toolCall(LLMToolCall(id: "c1", name: "run_command",
                                   argumentsJSON: #"{"command":"ls"}"#))],
            [.text("按新要求答")],
        ])
        let model = toolLoopModel(client)
        model.input = "列目录"
        await model.send(serverContext: "")
        XCTAssertEqual(model.state, .awaitingApproval)

        await model.submit(text: "只看隐藏文件", serverContext: "", delivery: .nextStep)
        XCTAssertEqual(model.queuedMessages.map(\.delivery), [.nextStep])

        await model.approveAndRun(id: "c1")

        XCTAssertEqual(client.captured.callCount, 2, "并进续轮，不另开一轮")
        XCTAssertTrue(model.queuedMessages.isEmpty)
        XCTAssertEqual(model.messages.map(\.role), [.user, .assistant, .user, .assistant])
        XCTAssertEqual(model.messages[2].text, "只看隐藏文件")
        XCTAssertTrue(model.messages[2].continuesTurn)
        XCTAssertEqual(model.messages.last?.text, "按新要求答")
        // 续轮发出去的会话：工具结果在前，这条消息紧随其后。
        let sent = client.captured.messages
        XCTAssertEqual(sent.map(\.role), [.user, .assistant, .user])
        XCTAssertEqual(sent[1].toolCalls.first?.output, "a")
        XCTAssertEqual(sent[2].text, "只看隐藏文件")
        XCTAssertEqual(model.state, .idle)
    }

    /// 已经排着的消息点「立即发送」：只送它，其余的仍等整轮结束。
    func testPromotedQueuedMessageIsDeliveredAtNextStepOthersWaitForTurnEnd() async {
        let client = MockLLMClient(scripts: [
            [.toolCall(LLMToolCall(id: "c1", name: "run_command",
                                   argumentsJSON: #"{"command":"ls"}"#))],
            [.text("续答")],
            [.text("答排队的那条")],
        ])
        let model = toolLoopModel(client)
        model.input = "列目录"
        await model.send(serverContext: "")

        await model.submit(text: "等整轮结束再说", serverContext: "")
        await model.submit(text: "这条现在就要", serverContext: "")
        model.sendQueuedAtNextStep(id: model.queuedMessages[1].id)
        XCTAssertEqual(model.queuedMessages.map(\.text), ["这条现在就要", "等整轮结束再说"])

        await model.approveAndRun(id: "c1")

        XCTAssertEqual(client.captured.callCount, 3)
        XCTAssertEqual(model.messages.filter { $0.role == .user }.map(\.text),
                       ["列目录", "这条现在就要", "等整轮结束再说"])
        XCTAssertEqual(model.messages.filter { $0.role == .user }.map(\.continuesTurn),
                       [false, true, false])
        XCTAssertEqual(model.messages.last?.text, "答排队的那条")
        XCTAssertTrue(model.queuedMessages.isEmpty)
    }

    /// 本轮没有下一步（模型直接答完）：攒着的几条一起开下一轮，而不是一条一轮。
    func testNextStepMessagesShareOneTurnWhenTheTurnEndsWithoutAStep() async {
        let client = MockLLMClient(scripts: [
            [.text("第一轮答完")],
            [.text("两条一起答")],
            [.text("答普通排队的")],
        ])
        let model = AssistantModel(client: client, provider: provider(), apiKey: "k")
        model.enqueue("普通排队")
        model.enqueue("甲", delivery: .nextStep)
        model.enqueue("乙", delivery: .nextStep)
        model.input = "你好"
        await model.send(serverContext: "")

        XCTAssertEqual(client.captured.callCount, 3)
        XCTAssertEqual(model.messages.map(\.text),
                       ["你好", "第一轮答完", "甲", "乙", "两条一起答", "普通排队", "答普通排队的"])
        XCTAssertFalse(model.messages[2].continuesTurn, "开新一轮的消息是轮次边界")
        XCTAssertTrue(model.queuedMessages.isEmpty)
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
