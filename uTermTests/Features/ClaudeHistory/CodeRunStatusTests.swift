import XCTest
@testable import uTerm

/// Code 标签页侧栏里跑着的会话那一行上的状态（`CodeRunStatus`）：程序经 OSC 7501 报的照写（含「空闲」），没报过什么都不写，
/// 「运行中」只留给程序真的报了在干活的时候。序列同 Claude Code 实测的样子（见 `TerminalProgramStatusTests`）。
@MainActor
final class CodeRunStatusTests: XCTestCase {
    private func report(_ pane: LocalShellPane, _ payload: String) {
        pane.session.feedOutput(text: "\u{1b}]7501;\(payload)\u{1b}\\")
    }

    private func status(_ pane: LocalShellPane, ended: Bool = false) -> CodeRunStatus {
        CodeRunStatus.of(isEnded: ended, report: pane.codeProgramStatus)
    }

    func test_not_reported_yet_is_not_running() {
        // 刚起来的 Claude Code 在第一条提示前不报状态：这时不能写「运行中」（之前写的是绿的「运行中」，和程序报的蓝的
        // 「运行中」是两个意思、一个字）。
        let pane = LocalShellPane()
        XCTAssertEqual(status(pane), .unreported)
        pane.session.dispose()
    }

    func test_working_shows_what_the_program_reported() {
        let pane = LocalShellPane()
        report(pane, "state=working:app=claude-code")
        XCTAssertEqual(status(pane), .program(ProgramStatusRecord(state: .working, app: "claude-code")))
        pane.session.dispose()
    }

    func test_idle_at_the_prompt_is_shown_as_idle() {
        // Claude Code 做完一轮、停在输入框：报 idle。终端标签上空闲不画圆点（`programStatus` 为 nil），侧栏这一行要写「空闲」。
        let pane = LocalShellPane()
        report(pane, "state=working:app=claude-code")
        report(pane, "state=idle:app=claude-code")
        XCTAssertNil(pane.session.programStatus, "终端标签：空闲不上圆点")
        guard case .program(let record) = status(pane) else { return XCTFail("空闲被当成没报过：\(status(pane))") }
        XCTAssertEqual(record.state, .idle)
        XCTAssertEqual(record.statusLabel, String(localized: "空闲"))
        pane.session.dispose()
    }

    func test_done_that_was_looked_at_becomes_idle_not_unreported() {
        // 做完了、用户看过了：结果不再提示，变回空闲。之前这一步之后侧栏那一行回落成「运行中」。
        let pane = LocalShellPane()
        report(pane, "state=done:app=claude-code")
        XCTAssertEqual(status(pane), .program(ProgramStatusRecord(state: .done, app: "claude-code")))
        pane.session.acknowledgeProgramStatus()
        guard case .program(let record) = status(pane) else { return XCTFail("看过的结果被当成没报过：\(status(pane))") }
        XCTAssertEqual(record.state, .idle)
        pane.session.dispose()
    }

    func test_ended_wins_over_any_report() {
        let pane = LocalShellPane()
        report(pane, "state=working:app=claude-code")
        XCTAssertEqual(status(pane, ended: true), .ended)
        pane.session.dispose()
    }

    func test_back_at_the_shell_prompt_drops_the_report() {
        // 程序退出、回到 shell 提示符（OSC 133 A）：在干活 / 等人的记录作废，又是没报过的样子。
        let pane = LocalShellPane()
        report(pane, "state=working:app=claude-code")
        pane.session.feedOutput(text: "\u{1b}]133;A\u{07}")
        XCTAssertEqual(status(pane), .unreported)
        pane.session.dispose()
    }
}
