import XCTest
@testable import uTerm

/// 「连上之后打一行命令」（iOS 的终端标签、远控镜像的「继续这个会话」）：先等连上，再等行编辑器，再打命令和回车。
/// 影子终端直接用 libghostty-vt 的那个，连接状态与代次用闭包模拟。
@MainActor
final class TerminalCommandTypingTests: XCTestCase {
    private final class Box {
        var connected = false
        var generation = 1
        var sent: [String] = []
    }

    private func makeShadow() -> ShadowTerminal {
        ShadowTerminal(cols: 80, rows: 24, options: TerminalScrollbackLimits(lines: 1_000).shadowOptions)
    }

    private func type(_ command: String, _ box: Box, _ shadow: ShadowTerminal,
                      connectTimeout: Duration = .seconds(5)) -> Task<Bool, Never> {
        Task {
            await TerminalCommandTyping.type(command, shadow: shadow, generation: { box.generation },
                                             isConnected: { box.connected }, connectTimeout: connectTimeout,
                                             send: { box.sent.append($0) })
        }
    }

    func testWaitsForConnectionAndLineEditorThenTypesCommandWithEnter() async {
        let box = Box(), shadow = makeShadow()
        let typing = type("claude --resume x", box, shadow)
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(box.sent, [], "没连上不打")
        box.connected = true
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(box.sent, [], "连上了、行编辑器还没起来（rc 还没跑完）也不打")
        // zsh 开始读一行时打开括号粘贴。
        shadow.feed(Data("Last login\r\n% \u{1B}[?2004h".utf8))
        let typed = await typing.value
        XCTAssertTrue(typed)
        XCTAssertEqual(box.sent, ["claude --resume x\r"])
    }

    func testGivesUpWhenNeverConnected() async {
        let box = Box(), shadow = makeShadow()
        let typed = await type("ls", box, shadow, connectTimeout: .milliseconds(150)).value
        XCTAssertFalse(typed)
        XCTAssertEqual(box.sent, [])
    }

    func testConnectionReplacedWhileWaitingIsNotTyped() async {
        let box = Box(), shadow = makeShadow()
        box.connected = true
        shadow.feed(Data("banner\r\n".utf8))   // 来过输出、行编辑器还没起来
        let typing = type("ls", box, shadow)
        try? await Task.sleep(for: .milliseconds(150))
        box.generation += 1                     // 断开重连：换了一条连接
        let typed = await typing.value
        XCTAssertFalse(typed)
        XCTAssertEqual(box.sent, [])
    }
}
