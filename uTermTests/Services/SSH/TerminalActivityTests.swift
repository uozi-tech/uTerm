import XCTest
@testable import uTerm

final class TerminalActivityTests: XCTestCase {

    // MARK: - 关闭确认

    func testIdleNeedsNoConfirmation() {
        XCTAssertNil(TerminalActivity.idle.closePrompt)
    }

    func testRunningProgramIsNamedInThePrompt() {
        XCTAssertEqual(TerminalActivity.running("vim").closePrompt?.title, "「vim」还在运行")
        XCTAssertNotNil(TerminalActivity.running(nil).closePrompt)
    }

    func testUnknownStillAsks() {
        XCTAssertNotNil(TerminalActivity.unknown.closePrompt)
    }

    func testAlternateScreenOnlyFillsInForUnknown() {
        XCTAssertEqual(TerminalActivity.unknown.resolved(alternateScreen: true), .running(nil))
        XCTAssertEqual(TerminalActivity.unknown.resolved(alternateScreen: false), .unknown)
        // 程序崩了留下备用屏时进程表更可信。
        XCTAssertEqual(TerminalActivity.idle.resolved(alternateScreen: true), .idle)
        XCTAssertEqual(TerminalActivity.running("top").resolved(alternateScreen: false), .running("top"))
    }

    // MARK: - 关窗确认

    func testWindowWithOnlyIdleTabsNeedsNoConfirmation() {
        XCTAssertNil(TerminalClosePrompt.forWindow([]))
        XCTAssertNil(TerminalClosePrompt.forWindow([.idle, .idle]))
    }

    func testWindowWithOneBusyTabNamesTheProgram() throws {
        let prompt = try XCTUnwrap(TerminalClosePrompt.forWindow([.idle, .running("npm")]))
        XCTAssertEqual(prompt.title, "「npm」还在运行")
        XCTAssertEqual(prompt.message, "关闭这个窗口可能会中断它。")
    }

    func testWindowWithSeveralBusyTabsCountsAndListsThem() throws {
        let prompt = try XCTUnwrap(TerminalClosePrompt.forWindow(
            [.running("npm"), .running("vim"), .running("npm"), .running(nil), .idle]))
        XCTAssertEqual(prompt.title, "有 4 个标签页还有程序在运行")
        XCTAssertEqual(prompt.message, "npm、vim。关闭这个窗口可能会中断它们。")
    }

    func testWindowWithOnlyUnknownTabsHedges() throws {
        let prompt = try XCTUnwrap(TerminalClosePrompt.forWindow([.unknown, .idle, .unknown]))
        XCTAssertEqual(prompt.title, "这个窗口里可能还有程序在运行")
        XCTAssertTrue(prompt.message.contains("有 2 个标签页"))
    }

    // MARK: - 解析 ps

    /// 一条 OpenSSH 连接：两个 shell（pts/0 空闲，pts/1 在跑 npm）+ 探测用的 sh。
    private let linuxOutput = """
    uterm-ps-begin 900
        1     0     1    -1 ?        systemd
      500     1   500    -1 ?        sshd
      600   500   600    -1 ?        sshd-session
      610   600   610    -1 ?        sshd-session
      700   610   700   700 pts/0    zsh
      701   700   701   700 pts/0    gitstatusd
      800   610   800   820 pts/1    bash
      820   800   820   820 pts/1    npm
      900   610   900    -1 ?        sh
      901   900   900    -1 ?        ps
    uterm-ps-end
    """

    func testFindsEveryShellOnThisConnection() throws {
        let table = try XCTUnwrap(RemoteProcessTable(output: linuxOutput))
        XCTAssertEqual(table.shells.map(\.pid), [700, 800])
        XCTAssertEqual(table.shells.map(\.tty), ["pts/0", "pts/1"])
    }

    func testShellAtPromptIsIdleEvenWithBackgroundHelper() throws {
        let table = try XCTUnwrap(RemoteProcessTable(output: linuxOutput))
        XCTAssertEqual(table.activity(of: table.shells[0]), .idle)
    }

    func testForegroundProgramIsReportedByName() throws {
        let table = try XCTUnwrap(RemoteProcessTable(output: linuxOutput))
        XCTAssertEqual(table.activity(of: table.shells[1]), .running("npm"))
    }

    func testIgnoresOutputAroundTheMarkers() throws {
        let noisy = "Welcome to the server\nlast login: 1 2 3 4 5\n" + linuxOutput + "\nbye"
        XCTAssertEqual(try XCTUnwrap(RemoteProcessTable(output: noisy)).shells.count, 2)
    }

    func testMacOSPathsAndLoginDashAreCleaned() throws {
        let output = """
        uterm-ps-begin 90
          50     1    50     0 ??       /usr/libexec/sshd-session
          60    50    60    70 ttys001  -zsh
          70    60    70    70 ttys001  /opt/homebrew/bin/node
          90    50    90     0 ??       sh
        uterm-ps-end
        """
        let table = try XCTUnwrap(RemoteProcessTable(output: output))
        XCTAssertEqual(table.shells.map(\.name), ["zsh"])
        XCTAssertEqual(table.activity(of: table.shells[0]), .running("node"))
    }

    func testLoginShellThatExecedIntoAProgramCountsAsRunning() throws {
        let output = """
        uterm-ps-begin 90
          50     1    50    -1 ?        sshd
          60    50    60    60 pts/0    tmux: client
          90    50    90    -1 ?        sh
        uterm-ps-end
        """
        let table = try XCTUnwrap(RemoteProcessTable(output: output))
        XCTAssertEqual(table.activity(of: table.shells[0]), .running("tmux: client"))
    }

    func testExecViaLoginShellStillReachesTheSSHServer() throws {
        // fish 这类登录 shell 不 exec 最后一条命令：sh → fish → sshd。
        let output = """
        uterm-ps-begin 90
          50     1    50    -1 ?        sshd
          60    50    60    60 pts/0    fish
          80    50    80    -1 ?        fish
          90    80    90    -1 ?        sh
        uterm-ps-end
        """
        XCTAssertEqual(try XCTUnwrap(RemoteProcessTable(output: output)).shells.map(\.pid), [60])
    }

    func testRejectsTruncatedOrFailedOutput() {
        XCTAssertNil(RemoteProcessTable(output: ""))
        XCTAssertNil(RemoteProcessTable(output: "uterm-ps-begin 90\n  1 0 1 -1 ? init\n"))
        XCTAssertNil(RemoteProcessTable(output: "uterm-ps-begin 90\nps: unknown option\nuterm-ps-end\n"))
    }

    func testNoSSHServerAncestorMeansNoShells() throws {
        let output = """
        uterm-ps-begin 90
           1     0     1    -1 ?        init
          60     1    60    60 pts/0    bash
          90     1    90    -1 ?        sh
        uterm-ps-end
        """
        XCTAssertEqual(try XCTUnwrap(RemoteProcessTable(output: output)).shells, [])
    }

    // MARK: - 认 pty 的标记

    func testMarkerSplitAcrossChunks() {
        var scanner = TTYMarkerScanner()
        XCTAssertNil(scanner.feed(Data("output\u{1b}]69".utf8)))
        XCTAssertNil(scanner.feed(Data("74;pts/".utf8)))
        XCTAssertEqual(scanner.feed(Data("3\u{07}more".utf8)), "pts/3")
    }

    func testMarkerSurvivesLargeOutputBeforeIt() {
        var scanner = TTYMarkerScanner()
        XCTAssertNil(scanner.feed(Data(repeating: 0x41, count: 1_000_000)))
        XCTAssertEqual(scanner.feed(Data("\u{1b}]6974;ttys001\u{07}".utf8)), "ttys001")
    }

    func testOtherOSCIsNotAMarker() {
        var scanner = TTYMarkerScanner()
        XCTAssertNil(scanner.feed(Data("\u{1b}]0;title\u{07}\u{1b}]6973;S;abc\u{07}".utf8)))
    }

    func testMarkerCommandSkipsUnsafeNames() throws {
        let command = try XCTUnwrap(TTYMarkerScanner.command(forTTYs: ["pts/1", "x;rm -rf ~", "../etc", "ttys002"]))
        XCTAssertTrue(command.contains("for t in pts/1 ttys002;"))
        XCTAssertFalse(command.contains("rm"))
        XCTAssertFalse(command.contains(".."))
        XCTAssertNil(TTYMarkerScanner.command(forTTYs: ["$(id)"]))
    }

    /// 标记也会流到同一条连接上别的标签，那里没人接，不能显示出来。
    func testTerminalIgnoresTheMarker() {
        let terminal = ShadowTerminal(cols: 40, rows: 5, options: TerminalScrollbackLimits(lines: 100).shadowOptions)
        terminal.feed(Data("a\u{1b}]6974;pts/3\u{07}b".utf8))
        XCTAssertEqual(terminal.recentLines(1).lines, ["ab"])
    }
}
