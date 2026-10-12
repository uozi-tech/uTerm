import Foundation
import XCTest
@testable import uTerm

/// Agent 对话的 `run_command` 执行器：跑在 `SupervisedExec` 看门狗底下，卡死的命令到点
/// 被终止并折成失败，而不是让工具卡片永远停在「执行中」。执行器全是注入的闭包，不碰网络。
final class SupervisedAgentCommandExecutorTests: XCTestCase {
    private enum Failure: Error { case connect }

    /// 记下走 `exec` 的命令（看门狗杀进程组走这条）。
    private final class RawLog: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        var commands: [String] { lock.withLock { stored } }
        func record(_ command: String) { lock.withLock { stored.append(command) } }
    }

    func testCompletedCommandReturnsOutputAndExitCode() async throws {
        let base = SSHCommandExecutor(
            exec: { _ in "" },
            execStream: { _, onOutput in
                onOutput(Data("\(SSHCommandExecutor.pidMarker):7\nhello\n\n\(SSHCommandExecutor.sentinel):3\n".utf8))
            })
        let result = try await SupervisedAgentCommandExecutor(base, tick: .milliseconds(10)).run("false")
        XCTAssertEqual(result.output, "hello")
        XCTAssertEqual(result.exitCode, 3)
    }

    func testSilentCommandIsKilledAndThrowsStalledWithPartialOutput() async throws {
        let log = RawLog()
        let base = SSHCommandExecutor(
            exec: { command in log.record(command); return "" },
            execStream: { _, onOutput in
                onOutput(Data("\(SSHCommandExecutor.pidMarker):4242\nbefore the hang\n".utf8))
                try await Task.sleep(for: .seconds(3600))
            })
        let executor = SupervisedAgentCommandExecutor(base, idle: .milliseconds(80), tick: .milliseconds(10))
        do {
            _ = try await executor.run("ps aux")
            XCTFail("应抛 AgentCommandStalled")
        } catch let stalled as AgentCommandStalled {
            XCTAssertEqual(stalled.partialOutput, "before the hang")
            XCTAssertTrue(stalled.reason.contains("已终止远端进程组"), stalled.reason)
            let text = stalled.localizedDescription
            XCTAssertTrue(text.hasPrefix("before the hang\n[执行超时："), text)
        }
        XCTAssertEqual(log.commands, [SupervisedExec.killScript(pid: 4242)])
    }

    /// 建连 / 传输失败原样上抛：卡片上的文案与接看门狗之前一致。
    func testConnectFailureRethrowsUnderlyingError() async {
        let base = SSHCommandExecutor(
            exec: { _ in "" },
            execStream: { _, _ in throw Failure.connect })
        do {
            _ = try await SupervisedAgentCommandExecutor(base, tick: .milliseconds(10)).run("ls")
            XCTFail("应抛错")
        } catch {
            XCTAssertEqual(error as? Failure, .connect)
        }
    }

    /// `AssistantModel` 在发命令时自己套看门狗：真 SSH 执行器被包一层，其余原样。
    func testAssistantModelSupervisesOnlyBareSSHExecutors() {
        let bare = SSHCommandExecutor(exec: { _ in "" })
        XCTAssertTrue(AssistantModel.supervised(bare) is SupervisedAgentCommandExecutor)
        let wrapped = SupervisedAgentCommandExecutor(bare, idle: .seconds(1))
        XCTAssertTrue(AssistantModel.supervised(wrapped) is SupervisedAgentCommandExecutor)
        let fake = MockCommandExecutor()
        XCTAssertTrue(AssistantModel.supervised(fake) is MockCommandExecutor)
    }

    func testProductionIdleBudgetIsAgentIdle() {
        XCTAssertEqual(SupervisedExec.agentIdle, .seconds(120))
        XCTAssertTrue(ToolSpec.runCommand.description.contains("120 秒"))
    }
}
