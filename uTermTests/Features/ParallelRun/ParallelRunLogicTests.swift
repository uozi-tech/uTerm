import XCTest
@testable import uTerm

/// 并行执行窗口的纯逻辑单测：AI 诊断 JSON 解析 + Shell 输出切行。
/// 非 `@MainActor`：验证这些 helper 确为 `nonisolated`、可在非主线程调用。
final class ParallelRunLogicTests: XCTestCase {

    // MARK: - ParallelAIDoctor.parseConclusion

    func testParseConclusionCleanObject() {
        let raw = #"{"status":"healed","summary":"更新后进程未起，已重启并验证 online。"}"#
        let c = ParallelAIDoctor.parseConclusion(raw)
        XCTAssertEqual(c?.status, "healed")
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
}
