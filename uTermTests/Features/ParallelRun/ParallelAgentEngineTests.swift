import AgentKit
import XCTest
@testable import uTerm

/// 两端共用的 `ParallelAgentEngine`：审批策略、执行与收尾、结论判定。
@MainActor
final class ParallelAgentEngineTests: XCTestCase {

    private func doctor(_ client: MockLLMClient) -> ParallelAIDoctor {
        var d = ParallelAIDoctor(client: client, model: "test",
                                 baseURL: URL(string: "https://example.invalid")!, apiKey: "k")
        d.retryDelay = { _ in .zero }
        return d
    }

    private func call(_ command: String) -> LLMEvent {
        let args = (try? JSONSerialization.data(withJSONObject: ["command": command]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return .toolCall(LLMToolCall(id: UUID().uuidString, name: "run_command", argumentsJSON: args))
    }

    private func request(initialExit: Int? = nil, hasInitial: Bool = false) -> ParallelAgentRequest {
        ParallelAgentRequest(goal: "更新软件包", command: hasInitial ? "apt-get upgrade -y" : "",
                             serverName: "web-01", endpoint: "root@10.0.0.1:22",
                             initial: hasInitial ? .init(output: "E: oops", exitCode: initialExit, note: nil) : nil)
    }

    /// 不审批：模型下发什么就执行什么，执行结果回喂，模型给结论后收尾。
    func testUnrestrictedExecutesAndConcludes() async {
        let llm = MockLLMClient(scripts: [
            [call("apt-get -y upgrade")],
            [.text(#"{"status":"ok","summary":"已更新。"}"#)],
        ])
        var executed: [String] = []
        var events: [ParallelAgentEvent] = []
        let engine = ParallelAgentEngine(doctor: doctor(llm), approval: .unrestricted, host: "测试")
        let outcome = await engine.run(request(), execute: { command in
            executed.append(command)
            return .completed(CommandResult(output: "done", exitCode: 0))
        }, onEvent: { events.append($0) })

        XCTAssertTrue(outcome.succeeded)
        XCTAssertEqual(outcome.summary, "已更新。")
        XCTAssertEqual(executed, ["apt-get -y upgrade"])
        XCTAssertTrue(events.contains { if case .stepFinished(0, _, let line) = $0 { return line.contains("退出码 0") }; return false })
        // 第二轮请求里带着第一条命令的真实输出。
        XCTAssertTrue(llm.captured.messages.contains { $0.toolCalls.contains { $0.output == "done" } })
    }

    /// 「每步确认」档：只记建议，不执行，判失败交人工。
    func testConfirmSafetyOnlySuggests() async {
        let llm = MockLLMClient(scripts: [[call("systemctl restart nginx")]])
        var executed = 0
        var suggestions: [String] = []
        let engine = ParallelAgentEngine(doctor: doctor(llm), approval: .safety(.confirm), host: "测试")
        let outcome = await engine.run(request(), execute: { _ in
            executed += 1
            return .completed(CommandResult(output: "", exitCode: 0))
        }, onEvent: { if case .suggested(let s) = $0 { suggestions.append(s) } })

        XCTAssertEqual(executed, 0, "每步确认档不该自动执行")
        XCTAssertFalse(outcome.succeeded)
        XCTAssertEqual(suggestions, ["建议执行：systemctl restart nginx"])
        XCTAssertTrue(outcome.summary.contains("每步确认"), outcome.summary)
    }

    /// 档位不自动执行时，系统提示词要告诉模型只给建议。
    func testSystemPromptMentionsSafetyOnlyWhenNotAutoExecuting() {
        XCTAssertTrue(ParallelAgentEngine.systemPrompt(host: "x", approval: .safety(.confirm)).contains("不允许自动执行写操作"))
        XCTAssertFalse(ParallelAgentEngine.systemPrompt(host: "x", approval: .safety(.auto)).contains("不允许自动执行写操作"))
        XCTAssertFalse(ParallelAgentEngine.systemPrompt(host: "x", approval: .unrestricted).contains("不允许自动执行写操作"))
        XCTAssertTrue(ParallelAgentEngine.systemPrompt(host: "iOS SSH 终端", approval: .unrestricted).contains("uTerm（iOS SSH 终端）"))
    }

    // MARK: - 结论判定

    func testInterruptedAfterExecutingIsFailedEvenIfLastExitZero() {
        let o = ParallelAgentEngine.conclude(conclusion: nil, interruption: "AI 服务请求失败（x）",
                                             stoppedForSafety: false, executedAny: true, stepCount: 3,
                                             lastExit: 0, initial: nil)
        XCTAssertFalse(o.succeeded)
        XCTAssertTrue(o.summary.contains("已执行 3 步"), o.summary)
    }

    func testInitialSuccessWithoutAgentStepsIsSuccess() {
        let o = ParallelAgentEngine.conclude(conclusion: nil, interruption: "AI 服务请求失败（x）",
                                             stoppedForSafety: false, executedAny: false, stepCount: 0,
                                             lastExit: 0, initial: .init(output: "", exitCode: 0, note: nil))
        XCTAssertTrue(o.succeeded)
        XCTAssertTrue(o.summary.contains("未做进一步复核"), o.summary)
    }

    func testModelVerdictWins() {
        let o = ParallelAgentEngine.conclude(conclusion: (status: "failed", summary: "证书过期"),
                                             interruption: nil, stoppedForSafety: false, executedAny: true,
                                             stepCount: 1, lastExit: 0, initial: nil)
        XCTAssertFalse(o.succeeded)
        XCTAssertEqual(o.summary, "证书过期")
    }
}
