import AgentKit
import Foundation
import SwiftData
import XCTest
@testable import uTermMobile

/// 并行执行「AI 介入」不再一遇错就交人工：模型请求失败会退避重试、命令卡住会交给 Agent
/// 接着处理、请求彻底失败时把原因写进结论；外加大屏 Shell 的分页。
///
/// 真控制器 + 脚本化的假模型 + 脚本化的假会话，全离线。
@MainActor
final class ParallelRunAgentTests: XCTestCase {

    // MARK: - 大屏分页

    func testShellPagesChunkFourPerPage() {
        XCTAssertEqual(ParallelRunView.shellPages(count: 0), [])
        XCTAssertEqual(ParallelRunView.shellPages(count: 3), [[0, 1, 2]])
        XCTAssertEqual(ParallelRunView.shellPages(count: 4), [[0, 1, 2, 3]])
        XCTAssertEqual(ParallelRunView.shellPages(count: 12).count, 3)
        XCTAssertEqual(ParallelRunView.shellPages(count: 9), [[0, 1, 2, 3], [4, 5, 6, 7], [8]])
    }

    // MARK: - 模型请求重试

    /// 改前：第一轮请求撞 429 就 break，这台直接落成「需人工介入」。
    func testRateLimitedTurnIsRetriedAndLaneSucceeds() async throws {
        let llm = ScriptedLLMClient([
            .fail(LLMClientError.httpError(status: 429, body: "rate limited")),
            .fail(LLMClientError.httpError(status: 529, body: "overloaded")),
            .reply([.toolCall(Self.call("apt-get -y autoremove"))]),
            .reply([.text(#"{"status":"ok","summary":"已更新并清理完毕。"}"#)]),
        ])
        let session = ScriptedSession(results: [CommandResult(output: "0 upgraded", exitCode: 0)])
        let lane = try await runSingleLane(llm: llm, session: session, command: "")

        XCTAssertEqual(lane.tone, .ok)
        XCTAssertEqual(lane.summary, "已更新并清理完毕。")
        XCTAssertEqual(lane.agentSteps.map(\.command), ["apt-get -y autoremove"])
        XCTAssertEqual(lane.agentSteps.first?.state, .ok)
        // 1 次连通性预检 `true` + 1 条 Agent 命令。
        XCTAssertEqual(session.commands, ["true", "apt-get -y autoremove"])
        XCTAssertEqual(llm.agentRequests, 4, "2 次失败 + 2 次成功；收尾汇总不带工具，不算在内")
    }

    /// 鉴权错误重试也没用：立刻放弃，把原因写进结论，而不是笼统的「需人工介入」。
    func testPermanentModelErrorExplainsWhy() async throws {
        let llm = ScriptedLLMClient([.fail(LLMClientError.httpError(status: 401, body: "bad key"))])
        let session = ScriptedSession(results: [CommandResult(output: "E: broken", exitCode: 100)])
        let lane = try await runSingleLane(llm: llm, session: session, command: "apt-get upgrade -y")

        XCTAssertEqual(lane.tone, .failed)
        XCTAssertTrue(lane.summary.contains("AI 服务请求失败"), lane.summary)
        XCTAssertTrue(lane.summary.contains("API Key"), lane.summary)
        XCTAssertEqual(llm.agentRequests, 1, "401 不该重试")
        XCTAssertNil(lane.activity, "落定后不再显示「正在…」")
    }

    // MARK: - 命令卡住交给 Agent

    /// 改前：AI 介入时初始命令被看门狗判卡住，直接收成「执行超时，请人工复核」，Agent 一步都不跑。
    func testStalledInitialCommandIsHandedToAgent() async throws {
        let llm = ScriptedLLMClient([
            .reply([.toolCall(Self.call("dpkg --configure -a"))]),
            .reply([.text(#"{"status":"ok","summary":"上次升级卡在半截，已收尾并完成升级。"}"#)]),
        ])
        let session = ScriptedSession(
            results: [CommandResult(output: "Setting up foo", exitCode: 0)],
            stallFirst: true)
        let lane = try await runSingleLane(llm: llm, session: session, command: "apt-get upgrade -y")

        XCTAssertEqual(lane.tone, .ok)
        XCTAssertEqual(session.commands, ["apt-get upgrade -y", "dpkg --configure -a"])
        XCTAssertTrue(lane.lines.contains { $0.kind == .err && $0.text.hasPrefix("执行超时") },
                      "原始输出里仍要看得到那次超时")
        let firstPrompt = llm.firstUserText
        XCTAssertTrue(firstPrompt.contains("判定卡住并已终止"), firstPrompt)
    }

    /// 轮数用完仍没给结论：如实说明，而不是凭最后一条退出码报成功。
    func testRunningOutOfTurnsIsReportedHonestly() async throws {
        let replies: [ScriptedLLMClient.Step] = (0..<ParallelAgentPolicy.maxTurns).map { i in
            .reply([.toolCall(Self.call("echo step \(i)"))])
        }
        let llm = ScriptedLLMClient(replies)
        let session = ScriptedSession(results: [CommandResult(output: "ok", exitCode: 0)])
        let lane = try await runSingleLane(llm: llm, session: session, command: "")

        XCTAssertEqual(lane.tone, .failed)
        XCTAssertTrue(lane.summary.contains("已用完 \(ParallelAgentPolicy.maxTurns) 轮"), lane.summary)
        XCTAssertEqual(lane.agentSteps.count, ParallelAgentPolicy.maxTurns)
        XCTAssertTrue(llm.sawToolOutput(containing: "最后一轮"), "倒数第二轮之后要提醒模型直接给结论")
    }

    // MARK: - 装配

    private static func call(_ command: String) -> LLMToolCall {
        let args = (try? JSONSerialization.data(withJSONObject: ["command": command]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return LLMToolCall(id: UUID().uuidString, name: "run_command", argumentsJSON: args)
    }

    private func runSingleLane(llm: ScriptedLLMClient, session: ScriptedSession,
                               command: String) async throws -> PServerState {
        let container = try MobileFixtures.modelContainer(seed: .smoke)
        let profile = try XCTUnwrap(try container.mainContext.fetch(FetchDescriptor<ServerProfile>()).first)
        var doctor = ParallelAIDoctor(client: llm, model: "test", baseURL: URL(string: "https://example.invalid")!,
                                    apiKey: "k")
        doctor.retryDelay = { _ in .zero }
        let controller = ParallelRunController(
            commandID: UUID(), commandName: "更新软件包", command: command,
            intent: "更新软件包并清理", aiAssisted: true, targets: [profile], doctor: doctor,
            store: QuickCommandStore(context: container.mainContext), container: container,
            executor: ScriptedExecutor(session: session))
        controller.start()
        for _ in 0..<200 where !(controller.states.first.map { $0.tone != .running } ?? false) {
            try await Task.sleep(for: .milliseconds(20))
        }
        let lane = try XCTUnwrap(controller.states.first)
        XCTAssertNotEqual(lane.tone, .running, "4 秒内没落定")
        controller.cancel()
        return lane
    }
}

// MARK: - 假模型

/// 按脚本逐次回应的 `LLMClient`：每次 `stream` 取下一步，失败就抛，回复就吐事件。
private nonisolated final class ScriptedLLMClient: LLMClient, @unchecked Sendable {
    enum Step { case fail(Error), reply([LLMEvent]) }

    private let lock = NSLock()
    private var steps: [Step]
    private var count = 0
    private var toolCount = 0
    private var history: [[ChatMessage]] = []

    init(_ steps: [Step]) { self.steps = steps }

    var requests: Int { lock.withLock { count } }
    /// 带 `run_command` 工具的请求（Agent 轮次），不含全部落定后的汇总请求。
    var agentRequests: Int { lock.withLock { toolCount } }
    var firstUserText: String { lock.withLock { history.first?.first?.text ?? "" } }

    func sawToolOutput(containing text: String) -> Bool {
        lock.withLock {
            history.contains { messages in
                messages.contains { $0.toolCalls.contains { ($0.output ?? "").contains(text) } }
            }
        }
    }

    func stream(messages: [ChatMessage], system: String,
                config: LLMRequestConfig) -> AsyncThrowingStream<LLMEvent, Error> {
        let step: Step = lock.withLock {
            count += 1
            // Agent 轮次的系统提示词讲 run_command；汇总请求的不讲（`config.tools` 是主线程隔离的，这里读不到）。
            if system.contains("run_command") { toolCount += 1 }
            history.append(messages)
            return steps.isEmpty
                ? .reply([.text(#"{"status":"failed","summary":"脚本用完"}"#)])
                : steps.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            switch step {
            case .fail(let error):
                continuation.finish(throwing: error)
            case .reply(let events):
                for event in events { continuation.yield(event) }
                continuation.finish()
            }
        }
    }
}

// MARK: - 假会话

private nonisolated final class ScriptedSession: ParallelExecutionSession, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [CommandResult]
    private var stallPending: Bool
    private var log: [String] = []

    init(results: [CommandResult], stallFirst: Bool = false) {
        self.results = results
        self.stallPending = stallFirst
    }

    var commands: [String] { lock.withLock { log } }
    var setupErrorText: String? { nil }

    func run(_ command: String,
             onLines: @escaping @Sendable ([PLine]) -> Void) async throws -> CommandResult {
        let (stall, result): (Bool, CommandResult) = lock.withLock {
            log.append(command)
            if stallPending {
                stallPending = false
                return (true, CommandResult(output: "", exitCode: nil))
            }
            // 预检 `true` 不消耗脚本。
            if command == "true" { return (false, CommandResult(output: "", exitCode: 0)) }
            return (false, results.count > 1 ? results.removeFirst() : (results.first ?? CommandResult(output: "", exitCode: 0)))
        }
        if stall {
            let stalled = SupervisedExec.Stalled(
                reason: .idle, partial: CommandResult(output: "Unpacking foo ...", exitCode: nil),
                kill: .signalled)
            throw ParallelExecutionStalled(stalled: stalled, message: "连续 120 秒没有任何输出，判定卡住，已终止。")
        }
        return result
    }

    func takeHostKeyChallenge() -> HostKeyChallenge? { nil }
    func close() async {}
}

private struct ScriptedExecutor: ParallelCommandExecuting {
    let session: ScriptedSession
    func makeSession(for profile: ServerProfile, trustNewKeys: Bool) async -> ParallelExecutionSession {
        session
    }
}
