import XCTest
@testable import uTerm

/// `terminal open -- <命令>` 打进 shell 的那一行：屏幕上回显的包装（前后两个 `printf`）在开始标记到达时改写成只剩命令。
/// 直接用影子终端（libghostty-vt）核排版；经泵、经会话的整条路在 `ControlTerminalHandlerTests`。
@MainActor
final class TrackedRunEchoRewriteTests: XCTestCase {
    private func makeTerminal(cols: UInt16, rows: UInt16 = 10) -> ShadowTerminal {
        ShadowTerminal(cols: cols, rows: rows, options: TerminalScrollbackLimits(lines: 1_000).shadowOptions)
    }

    private func feed(_ terminal: ShadowTerminal, _ text: String) {
        terminal.feed(Data(text.utf8))
    }

    private func screenLines(_ terminal: ShadowTerminal) -> [String] {
        var lines = terminal.viewportText().components(separatedBy: "\n")
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        return lines
    }

    /// 提示符 + 行编辑器回显的整行 + 回车 + 开始标记，然后照计划改写。返回计划。
    @discardableResult
    private func echoAndRewrite(_ terminal: ShadowTerminal, run: TerminalTrackedRun, before: String = "Last login\r\n% ",
                                file: StaticString = #filePath, line: UInt = #line) throws -> TrackedRunEchoRewrite.Plan {
        feed(terminal, before + run.inputLine + "\r\n")
        terminal.feed(run.startMarkerBytes)
        let span = try XCTUnwrap(terminal.locateEcho(prefix: run.echoPrefix, suffix: run.echoSuffix),
                                 "找得到回显", file: file, line: line)
        let plan = try XCTUnwrap(TrackedRunEchoRewrite.plan(span: span, command: run.command),
                                 "能改写", file: file, line: line)
        terminal.feed(plan.bytes)
        return plan
    }

    func testInputLineStartsWithASpaceAndWrapsTheCommandInASubshell() {
        let run = TerminalTrackedRun(command: "uptime")
        XCTAssertTrue(run.inputLine.hasPrefix(" printf '\\033]6973;S;\(run.id)\\007'; (uptime); "),
                      "行首空格：开了 HIST_IGNORE_SPACE 的 shell 不记进历史")
        XCTAssertTrue(run.inputLine.hasSuffix("printf '\\033]6973;D;\(run.id);%s\\007' \"$?\""))
        XCTAssertEqual(run.startMarkerBytes, Data("\u{1B}]6973;S;\(run.id)\u{07}".utf8))
    }

    /// 不包子 shell 的那种（「继续这个会话」）：命令里的 `cd` 要留在窗口里。回显照样改写成只剩命令。
    func testRunOutsideASubshellHasNoParenthesesAndStillRewrites() throws {
        let command = "cd -- '/srv/it'\\''s a dir' && claude --resume 0b0e5f3a-1c2d-4e5f-8a9b-0c1d2e3f4a5b"
        let run = TerminalTrackedRun(command: command, inSubshell: false)
        XCTAssertEqual(run.inputLine,
                       " printf '\\033]6973;S;\(run.id)\\007'; \(command); printf '\\033]6973;D;\(run.id);%s\\007' \"$?\"")

        let terminal = makeTerminal(cols: 60)
        try echoAndRewrite(terminal, run: run)
        feed(terminal, "resumed\r\n")
        XCTAssertEqual(screenLines(terminal).joined(), "Last login% " + command + "resumed")
    }

    /// 包装折成三行，改写后只剩命令一行，下面的输出接在它正下方，读输出不丢行、命令行不和输出并成一行。
    func testWrappedEchoCollapsesToTheCommandAndOutputFollows() throws {
        let terminal = makeTerminal(cols: 40)
        let run = TerminalTrackedRun(command: "sudo ./bootstrap.zsh")
        let plan = try echoAndRewrite(terminal, run: run)
        XCTAssertEqual(plan.outputRow, 2)
        feed(terminal, "Password:\r\nupdated\r\n")

        XCTAssertEqual(screenLines(terminal), ["Last login", "% sudo ./bootstrap.zsh", "Password:", "updated"])
        let output = try XCTUnwrap(terminal.markRow(plan.outputRow))
        XCTAssertEqual(terminal.text(from: output, to: nil).text, "Password:\nupdated")
        let commandRow = try XCTUnwrap(terminal.markRow(1))
        XCTAssertTrue(terminal.text(from: commandRow, to: nil).text.hasPrefix("% sudo ./bootstrap.zsh\nPassword:"),
                      "命令那一行的软折行标记清掉了")
    }

    /// 命令自己就要折行（含宽字），按屏幕上量到的字宽排，折行处和引擎一致。
    func testLongCommandWithWideCharactersKeepsItsOwnWrapping() throws {
        let terminal = makeTerminal(cols: 20, rows: 20)
        let command = "echo 你好世界 && ls /var/log/nginx"
        let run = TerminalTrackedRun(command: command)
        let plan = try echoAndRewrite(terminal, run: run, before: "$ ")
        feed(terminal, "access.log\r\n")

        let lines = screenLines(terminal)
        XCTAssertEqual(lines.joined(), "$ \(command)access.log")
        XCTAssertEqual(lines.last, "access.log")
        XCTAssertEqual(plan.outputRow, lines.count - 1)
        let start = try XCTUnwrap(terminal.markRow(0))
        XCTAssertEqual(terminal.text(from: start, to: nil).text, "$ \(command)\naccess.log")
        XCTAssertFalse(terminal.viewportText().contains("6973"))
    }

    /// 命令正好填满一行（光标悬在行尾）：不多删也不少删。
    func testCommandFillingTheRowExactly() throws {
        let terminal = makeTerminal(cols: 24)
        let run = TerminalTrackedRun(command: String(repeating: "x", count: 22))
        let plan = try echoAndRewrite(terminal, run: run, before: "% ")
        feed(terminal, "ok\r\n")
        XCTAssertEqual(screenLines(terminal), ["% " + run.command, "ok"])
        XCTAssertEqual(plan.outputRow, 1)
    }

    /// 早打进去的那一份（行编辑器起来之前终端驱动回显的）不动，只改最后那一份。
    func testOnlyTheLastEchoIsRewritten() throws {
        let terminal = makeTerminal(cols: 200)
        let run = TerminalTrackedRun(command: "uptime")
        try echoAndRewrite(terminal, run: run, before: run.inputLine + "\r\n% ")
        let lines = screenLines(terminal)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines.last, "% uptime")
    }

    func testNothingToRewriteWithoutTheEcho() {
        let terminal = makeTerminal(cols: 40)
        let run = TerminalTrackedRun(command: "uptime")
        feed(terminal, "% uptime\r\n")
        terminal.feed(run.startMarkerBytes)
        XCTAssertNil(terminal.locateEcho(prefix: run.echoPrefix, suffix: run.echoSuffix))
    }

    func testOnTheAlternateScreenNothingIsFound() {
        let terminal = makeTerminal(cols: 200)
        let run = TerminalTrackedRun(command: "vim")
        feed(terminal, "% " + run.inputLine + "\r\n\u{1B}[?1049h")
        XCTAssertNil(terminal.locateEcho(prefix: run.echoPrefix, suffix: run.echoSuffix))
    }

    /// 屏幕上的字数和命令对不上（控制字符被画成 ^X 之类）就不改。
    func testMismatchedEchoIsLeftAlone() {
        let span = ShadowTerminal.EchoSpan(
            startRow: 0, startColumn: 2, endRow: 1, middleWidths: [1, 1, 1], cols: 40,
            cursor: .init(x: 0, y: 2, pendingWrap: false, visible: true))
        XCTAssertNil(TrackedRunEchoRewrite.plan(span: span, command: "ab"))
        XCTAssertNil(TrackedRunEchoRewrite.plan(span: span, command: "a\tb"))
        XCTAssertNotNil(TrackedRunEchoRewrite.plan(span: span, command: "abc"))
    }

    func testInjectionGate() {
        typealias Gate = TrackedRunInjectionGate
        XCTAssertTrue(Gate.isReady(lineEditorReady: true, sawOutput: false, quietFor: 0, waited: 0))
        XCTAssertFalse(Gate.isReady(lineEditorReady: false, sawOutput: true, quietFor: 0.5, waited: 1),
                       "还在出 rc 的输出")
        XCTAssertTrue(Gate.isReady(lineEditorReady: false, sawOutput: true, quietFor: Gate.quietSeconds, waited: 2),
                      "不开括号粘贴的 shell：输出停了就当在等输入")
        XCTAssertFalse(Gate.isReady(lineEditorReady: false, sawOutput: false, quietFor: 3, waited: 3),
                       "一个字都还没来")
        XCTAssertTrue(Gate.isReady(lineEditorReady: false, sawOutput: false, quietFor: 0, waited: Gate.maxWaitSeconds))
    }
}
