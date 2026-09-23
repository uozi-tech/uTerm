import XCTest
@testable import uTerm

/// 并行执行窗口的纯逻辑单测：AI 诊断 JSON 解析 + Shell 输出切行。
/// 非 `@MainActor`：验证这些 helper 确为 `nonisolated`、可在非主线程调用。
final class ParallelRunLogicTests: XCTestCase {

    // MARK: - ParallelAIDoctor.parseConclusion

    func testParseConclusionCleanObject() {
        // 结论只判 ok|failed —— 修复后达成也统一报 ok（不再单列 healed）。
        let raw = #"{"status":"ok","summary":"更新后进程未起，已重启并验证 online。"}"#
        let c = ParallelAIDoctor.parseConclusion(raw)
        XCTAssertEqual(c?.status, "ok")
        XCTAssertEqual(c?.summary, "更新后进程未起，已重启并验证 online。")
    }

    func testParseConclusionToleratesProseAndFencesAndLowercasesStatus() {
        let raw = """
        好的，结论如下：
        ```json
        {"status":"OK","summary":"已是最新，无需修复。"}
        ```
        """
        let c = ParallelAIDoctor.parseConclusion(raw)
        XCTAssertEqual(c?.status, "ok")   // 归一化小写
        XCTAssertEqual(c?.summary, "已是最新，无需修复。")
    }

    func testParseConclusionGarbageReturnsNil() {
        XCTAssertNil(ParallelAIDoctor.parseConclusion("我还在排查"))
        XCTAssertNil(ParallelAIDoctor.parseConclusion(""))
        XCTAssertNil(ParallelAIDoctor.parseConclusion(#"{"status":"","summary":""}"#))
    }

    func testParseConclusionSummaryOnlyStillParses() {
        // 只有 summary、缺 status：仍可用（status 空，调用方据执行情况推断语气）。
        let c = ParallelAIDoctor.parseConclusion(#"{"summary":"  搞定了  "}"#)
        XCTAssertEqual(c?.status, "")
        XCTAssertEqual(c?.summary, "搞定了")
    }

    // MARK: - ParallelRunModel.outputLines

    /// 提示词要跟看门狗的真实行为一致：按静默判超时、超时会终止进程，而不是「远端还在跑」。
    func testAgentPromptDescribesIdleTimeoutAndTermination() {
        let prompt = ParallelRunModel.agentSystemPrompt(autoExecute: true, safetyLabel: "自动")
        XCTAssertTrue(prompt.contains("连续约 \(ParallelRunModel.idleSeconds) 秒没有任何输出"), prompt)
        XCTAssertTrue(prompt.contains("终止"))
        XCTAssertFalse(prompt.contains("远端进程通常仍在后台继续"), "看门狗现在会杀进程组，旧说法会误导模型")
    }

    func testOutputLinesNilResultIsError() {
        let lines = ParallelRunModel.outputLines(from: nil, failed: true)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?.kind, .err)
    }

    func testOutputLinesSuccessAllOut() {
        let r = CommandResult(output: "line1\nline2", exitCode: 0)
        let lines = ParallelRunModel.outputLines(from: r, failed: false)
        XCTAssertEqual(lines.map(\.text), ["line1", "line2"])
        XCTAssertTrue(lines.allSatisfy { $0.kind == .out })
    }

    func testOutputLinesFailedMarksLastLineError() {
        let r = CommandResult(output: "starting\nerror: boom", exitCode: 1)
        let lines = ParallelRunModel.outputLines(from: r, failed: true)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].kind, .out)
        XCTAssertEqual(lines[1].kind, .err)
        XCTAssertEqual(lines[1].text, "error: boom")
    }

    func testOutputLinesEmptyOutputPlaceholders() {
        let ok = ParallelRunModel.outputLines(from: CommandResult(output: "", exitCode: 0), failed: false)
        XCTAssertEqual(ok.map(\.text), ["done."])
        let fail = ParallelRunModel.outputLines(from: CommandResult(output: "", exitCode: 1), failed: true)
        XCTAssertEqual(fail.map(\.text), ["（无输出）"])
    }

    func testParallelOutputUsesLazyRowsAndCoalescedTailFollowing() throws {
        let shellSource = try String(contentsOf: repoRoot.appendingPathComponent(
            "uTerm/Features/ParallelRun/Views/ParallelShellGrid.swift"),
                                     encoding: .utf8)
        let agentSource = try String(contentsOf: repoRoot.appendingPathComponent(
            "uTerm/Features/ParallelRun/Views/ParallelAgentView.swift"),
                                     encoding: .utf8)

        XCTAssertTrue(shellSource.contains("LazyVStack(alignment: .leading, spacing: 1)"))
        XCTAssertTrue(shellSource.contains(".onScrollPhaseChange"))
        XCTAssertTrue(agentSource.contains(".onScrollPhaseChange"))
        XCTAssertTrue(shellSource.contains("AgentScrollPolicy.coalescingDelay"))
        XCTAssertTrue(agentSource.contains("AgentScrollPolicy.coalescingDelay"))
        XCTAssertFalse(shellSource.contains("withAnimation(.easeOut(duration: 0.18))"))
        XCTAssertFalse(agentSource.contains("withAnimation(.easeOut(duration: 0.2))"))
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
