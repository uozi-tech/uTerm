import Foundation
import XCTest
@testable import uTerm

/// `SupervisedExec`：按静默判卡死、总时长兜底、超时后杀进程组、输出裁剪不再整条失败。
/// 执行器全是注入的闭包，不碰网络。
final class SupervisedExecTests: XCTestCase {

    // MARK: 夹具

    /// 远端的替身：流式 exec 按脚本吐输出；`exec`（杀进程组走这条）记下收到的命令，
    /// 并让还在「跑」的流式命令结束 —— 就像远端进程组真被杀了。
    private final class FakeRemote: @unchecked Sendable {
        private let lock = NSLock()
        private var rawCommands: [String] = []
        private var killed = false

        var commands: [String] { lock.withLock { rawCommands } }
        var isKilled: Bool { lock.withLock { killed } }

        func recordRaw(_ command: String) {
            lock.withLock {
                rawCommands.append(command)
                killed = true
            }
        }

        /// 脚本化的流式 exec：先报 pid，再按 `chunks` 逐块吐（每块前等 `gap`），
        /// `finish` 为 false 时吐完就挂着，直到被杀。
        func executor(
            pid: Int32? = 4242,
            chunks: [String] = [],
            gap: Duration = .zero,
            exitCode: Int? = 0,
            finish: Bool = true,
            maxBytes: Int = 16_000
        ) -> SSHCommandExecutor {
            SSHCommandExecutor(
                maxLines: 100_000,
                maxBytes: maxBytes,
                exec: { [self] command in
                    recordRaw(command)
                    return ""
                },
                execStream: { [self] _, onOutput in
                    if let pid { onOutput(Data("\(SSHCommandExecutor.pidMarker):\(pid)\n".utf8)) }
                    for chunk in chunks {
                        if gap > .zero { try? await Task.sleep(for: gap) }
                        if isKilled { return }
                        onOutput(Data(chunk.utf8))
                    }
                    guard finish else {
                        while !isKilled { try? await Task.sleep(for: .milliseconds(10)) }
                        return
                    }
                    if let exitCode {
                        onOutput(Data("\n\(SSHCommandExecutor.sentinel):\(exitCode)\n".utf8))
                    }
                }
            )
        }
    }

    private func limits(
        idle: Duration = .seconds(60),
        maxDuration: Duration = .seconds(3600),
        maxBytes: Int = 16_000
    ) -> SupervisedExec.Limits {
        SupervisedExec.Limits(idle: idle, maxDuration: maxDuration, maxLines: 100_000, maxBytes: maxBytes)
    }

    // MARK: 正常结束

    func testCompletedCommandStripsThePIDLineAndKeepsTheExitCode() async {
        let remote = FakeRemote()
        let outcome = await SupervisedExec.run(
            "false", on: remote.executor(chunks: ["hello\n"], exitCode: 3), limits: limits())
        guard case .completed(let result) = outcome else {
            return XCTFail("应当正常结束，实得 \(outcome)")
        }
        XCTAssertEqual(result.output, "hello")
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertFalse(result.truncated)
        XCTAssertTrue(remote.commands.isEmpty, "正常结束不该去杀任何东西")
    }

    /// 看门狗每拍最长 1 秒，但命令结束要**立刻**返回，不能让每条 `run` 都白等一拍。
    func testReturnsAsSoonAsTheCommandFinishes() async {
        let remote = FakeRemote()
        let started = ContinuousClock.now
        _ = await SupervisedExec.run("true", on: remote.executor(), limits: limits())
        XCTAssertLessThan(ContinuousClock.now - started, .milliseconds(500))
    }

    /// 比静默预算跑得久、但一直有输出的命令不该被判卡死 —— 这正是改成按静默判的目的。
    func testSlowButChattyCommandOutlivesTheIdleBudget() async {
        let remote = FakeRemote()
        let executor = remote.executor(
            chunks: Array(repeating: "step\n", count: 10), gap: .milliseconds(100))
        let outcome = await SupervisedExec.run(
            "apt-get upgrade", on: executor,
            limits: limits(idle: .milliseconds(400)), tick: .milliseconds(20))
        guard case .completed(let result) = outcome else {
            return XCTFail("持续有输出的命令被当成卡死了：\(outcome)")
        }
        XCTAssertEqual(result.output.components(separatedBy: "\n").count, 10)
    }

    /// 输出比上限大：以前整条抛 `commandOutputTooLarge`，现在是裁剪 + 退出码照拿。
    func testOversizedOutputIsTruncatedNotFailed() async {
        let remote = FakeRemote()
        let big = String(repeating: "x", count: 200_000)
        let outcome = await SupervisedExec.run(
            "cat big", on: remote.executor(chunks: [big], exitCode: 0, maxBytes: 1_000),
            limits: limits(maxBytes: 1_000))
        guard case .completed(let result) = outcome else {
            return XCTFail("输出大不该让整条失败：\(outcome)")
        }
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.exitCode, 0, "退出码哨兵在尾部，裁掉中间也得拿得到")
        XCTAssertLessThan(result.output.utf8.count, 1_100)
    }

    // MARK: 超时

    func testSilentCommandIsKilledAfterTheIdleBudget() async {
        let remote = FakeRemote()
        let executor = remote.executor(chunks: ["partial\n"], finish: false)
        let outcome = await SupervisedExec.run(
            "sleep 3600", on: executor,
            limits: limits(idle: .milliseconds(300)), tick: .milliseconds(20))
        guard case .stalled(let stalled) = outcome else {
            return XCTFail("静默命令应当被判卡住：\(outcome)")
        }
        XCTAssertEqual(stalled.reason, .idle)
        XCTAssertEqual(stalled.kill, .signalled)
        XCTAssertEqual(stalled.partial.output, "partial", "判定前的输出要带回来")
        XCTAssertNil(stalled.partial.exitCode)
        XCTAssertEqual(remote.commands.count, 1)
        XCTAssertTrue(remote.commands[0].hasPrefix("kill -TERM -4242"), remote.commands[0])
        XCTAssertTrue(remote.commands[0].contains("kill -KILL -4242"), "宽限到点要补 KILL")
    }

    /// `tail -f` 这类永远在出输出的命令不会静默，靠总时长上限兜底。
    func testChattyCommandHitsTheMaxDuration() async {
        let remote = FakeRemote()
        let executor = remote.executor(
            chunks: Array(repeating: "log\n", count: 1_000), gap: .milliseconds(20), finish: false)
        let outcome = await SupervisedExec.run(
            "tail -f /var/log/syslog", on: executor,
            limits: limits(idle: .seconds(5), maxDuration: .milliseconds(400)),
            tick: .milliseconds(20))
        guard case .stalled(let stalled) = outcome else {
            return XCTFail("应当撞上总时长上限：\(outcome)")
        }
        XCTAssertEqual(stalled.reason, .maxDuration)
        XCTAssertEqual(stalled.kill, .signalled)
    }

    /// 调用方取消（iOS 拆窗）：不等静默预算，也不陪着等终止宽限，马上返回并在后台杀进程组。
    func testCancellationReturnsPromptlyAndKillsInTheBackground() async throws {
        let remote = FakeRemote()
        let executor = remote.executor(chunks: ["working\n"], finish: false)
        let budget = limits(idle: .seconds(60))
        let task = Task {
            await SupervisedExec.run("sleep 3600", on: executor, limits: budget, tick: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(150))
        let cancelledAt = ContinuousClock.now
        task.cancel()
        let outcome = await task.value
        XCTAssertLessThan(ContinuousClock.now - cancelledAt, .milliseconds(500))
        guard case .stalled(let stalled) = outcome else { return XCTFail("取消应当收成 stalled：\(outcome)") }
        XCTAssertEqual(stalled.reason, .cancelled)
        XCTAssertEqual(stalled.kill, .signalled)
        XCTAssertEqual(stalled.partial.output, "working")
        for _ in 0..<100 where remote.commands.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(remote.commands.first?.hasPrefix("kill -TERM -4242") == true, "后台应当发出进程组终止")
    }

    /// 拿不到 pid（底层只会整段返回）就没法杀，退回「放手不等」。
    func testWithoutAPIDTheCommandIsAbandonedNotKilled() async {
        let executor = SSHCommandExecutor(maxLines: 200, maxBytes: 16_000) { command in
            if command.hasPrefix("kill") { return "" }
            try? await Task.sleep(for: .seconds(30))
            return ""
        }
        let outcome = await SupervisedExec.run(
            "sleep 3600", on: executor,
            limits: limits(idle: .milliseconds(200)), tick: .milliseconds(20))
        guard case .stalled(let stalled) = outcome else {
            return XCTFail("应当超时：\(outcome)")
        }
        XCTAssertEqual(stalled.kill, .noPID)
    }

    /// 看门狗要一直给外层（`ControlServer` 的静默闸）报进展，否则长命令会先被 IPC 层掐掉。
    func testWatchdogReportsProgressWhileWaiting() async {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func bump() { lock.withLock { value += 1 } }
            var count: Int { lock.withLock { value } }
        }
        let counter = Counter()
        let remote = FakeRemote()
        let executor = remote.executor(chunks: ["a\n", "b\n"], gap: .milliseconds(150))
        _ = await IOActivity.$pulse.withValue({ counter.bump() }) {
            await SupervisedExec.run(
                "slow", on: executor, limits: limits(), tick: .milliseconds(20))
        }
        XCTAssertGreaterThan(counter.count, 3, "300 ms 的命令、20 ms 一拍，看门狗应当报过多次进展")
    }

    // MARK: GUI 入口

    /// GUI 没有逐次参数：阈值取 `interactive*`，输出裁剪沿用执行器自己的。
    func testInteractiveLimitsUseTheExecutorsOwnOutputCaps() {
        let executor = SSHCommandExecutor(maxLines: 77, maxBytes: 8_888) { _ in "" }
        let limits = SupervisedExec.interactiveLimits(for: executor)
        XCTAssertEqual(limits.idle, SupervisedExec.interactiveIdle)
        XCTAssertEqual(limits.maxDuration, SupervisedExec.interactiveMaxDuration)
        XCTAssertEqual(limits.maxLines, 77)
        XCTAssertEqual(limits.maxBytes, 8_888)
        XCTAssertGreaterThan(SupervisedExec.interactiveIdle, .seconds(ControlProtocol.defaultRunTimeoutSeconds),
                             "GUI 没法按条放宽，静默预算要比 CLI 默认宽")
    }

    func testStallMessageSaysWhetherTheRemoteWasStopped() {
        let limits = SupervisedExec.Limits(idle: .seconds(300), maxDuration: .seconds(3600), maxLines: 1, maxBytes: 1)
        let partial = CommandResult(output: "", exitCode: nil)
        let killed = SupervisedExec.Stalled(reason: .idle, partial: partial, kill: .signalled)
        XCTAssertTrue(killed.message(limits: limits).contains("连续 300 秒没有任何输出"))
        XCTAssertTrue(killed.message(limits: limits).contains("已终止远端进程组"))
        XCTAssertFalse(killed.message(limits: limits).contains("仍在远端运行"))

        let abandoned = SupervisedExec.Stalled(reason: .maxDuration, partial: partial, kill: .noPID)
        XCTAssertTrue(abandoned.message(limits: limits).contains("3600 秒总时长上限"))
        XCTAssertTrue(abandoned.message(limits: limits).contains("仍在远端运行"))
    }

    func testKillScriptTargetsTheWholeGroupAndAlwaysSucceeds() {
        let script = SupervisedExec.killScript(pid: 777)
        XCTAssertTrue(script.hasPrefix("kill -TERM -777 2>/dev/null || exit 0"))
        XCTAssertTrue(script.contains("kill -0 -777"))
        XCTAssertTrue(script.hasSuffix("kill -KILL -777 2>/dev/null; exit 0"))
    }

    func testPIDAnnouncingWrapperPrintsThePIDFirst() {
        let wrapped = SSHCommandExecutor.wrapAnnouncingPID("uptime")
        XCTAssertTrue(wrapped.hasPrefix("printf '__UTERM_PID__:%d\\n' \"$$\"\n( uptime\n) 2>&1;"), wrapped)
        XCTAssertTrue(wrapped.hasSuffix("printf '\\n__UTERM_EXIT__:%d\\n' \"$?\""), wrapped)
    }
}
