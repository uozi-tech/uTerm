import XCTest
@testable import uTerm

/// 影子终端（libghostty-vt）给 uTerm 读的那部分：OSC 事件、标记、读屏、kitty 键盘标志、就地还原快照。
/// 快照 / 回放流本身的往返在 iOS 的 `ShadowTerminalTests`（同一份共享代码）。不建 surface、不要窗口。
final class ShadowTerminalReadingTests: XCTestCase {
    private func makeTerminal(cols: UInt16 = 40, rows: UInt16 = 10) -> ShadowTerminal {
        ShadowTerminal(cols: cols, rows: rows, options: TerminalScrollbackLimits(lines: 10_000).shadowOptions)
    }

    private final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [ShadowTerminal.Event] = []
        private var historyFlags: [Bool] = []
        func append(_ event: ShadowTerminal.Event, history: Bool = false) {
            lock.withLock {
                storage.append(event)
                historyFlags.append(history)
            }
        }
        var events: [ShadowTerminal.Event] { lock.withLock { storage } }
        var history: [Bool] { lock.withLock { historyFlags } }
    }

    private func recording(_ terminal: ShadowTerminal) -> EventLog {
        let log = EventLog()
        terminal.setEventHandler { log.append($0, history: $1) }
        return log
    }

    private func feed(_ terminal: ShadowTerminal, _ text: String) {
        terminal.feed(Data(text.utf8))
    }

    // MARK: 事件

    func testProgramStatusReportsAreDecoded() {
        let terminal = makeTerminal()
        let log = recording(terminal)
        feed(terminal, "\u{1B}]7501;state=blocked:kind=permission:app=claude-code:msg=QXBwbHk/\u{1B}\\")
        feed(terminal, "\u{1B}]7501;state=working:id=build/test:progress=40:title=VGVzdA==\u{07}")
        feed(terminal, "\u{1B}]7501;state=clear\u{07}")
        feed(terminal, "\u{1B}]7501;state=bogus\u{07}")

        guard log.events.count == 3 else { return XCTFail("事件数不对：\(log.events)") }
        guard case .programStatus(.report(let id, let record)) = log.events[0] else { return XCTFail("\(log.events[0])") }
        XCTAssertEqual(id, "")
        XCTAssertEqual(record, ProgramStatusRecord(state: .blocked, kind: .permission, progress: nil,
                                                   app: "claude-code", title: nil, message: "Apply?"))
        guard case .programStatus(.report(let childID, let child)) = log.events[1] else { return XCTFail("\(log.events[1])") }
        XCTAssertEqual(childID, "build/test")
        XCTAssertEqual(child, ProgramStatusRecord(state: .working, kind: nil, progress: 40, app: nil, title: "Test", message: nil))
        guard case .programStatus(.clear(id: nil)) = log.events[2] else { return XCTFail("\(log.events[2])") }
    }

    /// 查询的应答不走普通应答出口（那个出口前台是关着的），单独成事件；结束符跟着请求走。
    func testProgramStatusQueryIsAnEventEvenWhenRepliesAreOff() {
        let terminal = makeTerminal()
        let log = recording(terminal)
        let replies = EventLog()
        terminal.setReplyHandler { _ in replies.append(.bell) }
        feed(terminal, "\u{1B}]7501;?\u{07}")
        feed(terminal, "\u{1B}[c")   // DA：普通应答，出口关着就不答

        XCTAssertTrue(replies.events.isEmpty)
        guard log.events.count == 1, case .programStatusQuery(let reply) = log.events[0] else { return XCTFail("\(log.events)") }
        let text = String(decoding: reply, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("\u{1B}]7501;?"), text)
        XCTAssertTrue(text.hasSuffix("\u{07}"), "应答的结束符要和请求一样")

        terminal.setRepliesEnabled(true)
        feed(terminal, "\u{1B}]7501;?\u{1B}\\\u{1B}[c")
        XCTAssertEqual(replies.events.count, 1, "开了应答之后 DA 走普通出口，7501 仍然只走事件")
        XCTAssertEqual(log.events.count, 2)
    }

    func testPromptNotificationTitleAndBellEvents() {
        let terminal = makeTerminal()
        let log = recording(terminal)
        feed(terminal, "\u{1B}]133;A\u{07}")
        feed(terminal, "\u{1B}]133;C\u{07}")            // 不是提示符开始
        feed(terminal, "\u{1B}]9;构建完成\u{07}")
        feed(terminal, "\u{1B}]9;4;1;50\u{07}")         // 进度条，不是通知
        feed(terminal, "\u{1B}]777;notify;标题;正文\u{07}")
        feed(terminal, "\u{1B}]2;my title\u{07}\u{07}")

        var seen: [String] = []
        for event in log.events {
            switch event {
            case .promptStarted: seen.append("prompt")
            case .notification(let title, let body): seen.append("notify[\(title)|\(body)]")
            case .titleChanged(let title): seen.append("title[\(title)]")
            case .bell: seen.append("bell")
            default: seen.append("other")
            }
        }
        XCTAssertEqual(seen, ["prompt", "notify[|构建完成]", "notify[标题|正文]", "title[my title]", "bell"])
        XCTAssertEqual(terminal.title, "my title")
    }

    /// 备用屏里的 133 A 不算「程序结束了」（全屏程序自己画的提示符）。
    func testPromptOnAlternateScreenIsIgnored() {
        let terminal = makeTerminal()
        let log = recording(terminal)
        feed(terminal, "\u{1B}[?1049h\u{1B}]133;A\u{07}")
        XCTAssertTrue(log.events.isEmpty)
        XCTAssertTrue(terminal.isOnAlternateScreen)
    }

    /// 历史字节（接回时回放的那段）：事件带上历史标记；不应答（7501 查询、DA 都不答）、不写剪贴板、未知 OSC 不交出。
    /// 之后的实时字节照常。
    func testHistoryBytesAreMarkedAndNotAnswered() {
        let terminal = makeTerminal()
        terminal.reportUnknownOSC(withPrefixes: ["6973;"])
        let log = recording(terminal)
        let replies = EventLog()
        terminal.setReplyHandler { _ in replies.append(.bell) }
        terminal.setRepliesEnabled(true)
        let clipboard = EventLog()
        terminal.setClipboardWriteHandler { _ in clipboard.append(.bell) }
        terminal.feed(Data(("\u{1B}]7501;state=working\u{07}\u{1B}]7501;?\u{07}\u{1B}]9;x\u{07}\u{1B}]6973;S;abc\u{07}"
                            + "\u{1B}[c\u{1B}]52;c;\(Data("old".utf8).base64EncodedString())\u{07}\u{07}").utf8), asHistory: true)
        XCTAssertTrue(replies.events.isEmpty, "历史里的查询不答")
        XCTAssertTrue(clipboard.events.isEmpty, "历史里的 OSC 52 不写")
        XCTAssertEqual(log.history, Array(repeating: true, count: log.events.count), "历史事件都带标记")
        XCTAssertFalse(log.events.contains { if case .programStatusQuery = $0 { return true } else { return false } })
        XCTAssertFalse(log.events.contains { if case .unknownOSC = $0 { return true } else { return false } })
        XCTAssertTrue(log.events.contains { if case .programStatus = $0 { return true } else { return false } })

        let before = log.events.count
        feed(terminal, "\u{1B}[c\u{07}")
        XCTAssertEqual(replies.events.count, 1, "实时的照答")
        XCTAssertEqual(log.events.count, before + 1)
        XCTAssertEqual(log.history.last, false)
    }

    // MARK: 未知 OSC 与标记

    func testUnknownOSCCarriesPayloadAndCursorMarker() {
        let terminal = makeTerminal()
        terminal.reportUnknownOSC(withPrefixes: ["6973;"])
        let log = recording(terminal)
        feed(terminal, "$ run\r\n\u{1B}]6973;S;1a2b3c4d\u{07}line one\r\n\u{1B}]1337;SetMark\u{07}\u{1B}]69730;x\u{07}"
             + "line two\r\n\u{1B}]6973;D;1a2b3c4d;7\u{07}$ ")

        var markers: [ShadowTerminal.Marker] = []
        var payloads: [String] = []
        for case .unknownOSC(let payload, let cursor) in log.events {
            payloads.append(String(decoding: payload, as: UTF8.self))
            if let cursor { markers.append(cursor) }
        }
        XCTAssertEqual(payloads, ["6973;S;1a2b3c4d", "6973;D;1a2b3c4d;7"], "没登记的开头（1337、69730）不报")
        guard markers.count == 2 else { return XCTFail("每条未知 OSC 都要带光标标记") }
        XCTAssertEqual(markers[0].column, 0)
        let output = terminal.text(from: markers[0], to: markers[1])
        XCTAssertEqual(output.text, "line one\nline two")
        XCTAssertFalse(output.truncated)
    }

    /// 从快照建的、就地还原的影子：RIS 之后字素簇（mode 2027）仍是开的（关了的话 ZWJ 这类字符的宽度和 surface 对不上）。
    /// 快照带着源终端的模式默认值；三条建法又都按选项设一遍，结果一样。
    func testSnapshotRestoredTerminalKeepsGraphemeClustersAcrossReset() throws {
        let source = makeTerminal()
        feed(source, "hello")
        XCTAssertTrue(source.isModeSet(2027), "用例前提：新建的默认开")
        let snapshot = try source.snapshot()
        let built = try ShadowTerminal(snapshot: snapshot, options: TerminalScrollbackLimits(lines: 10_000).shadowOptions)
        let restored = makeTerminal()
        try restored.restore(snapshot: snapshot)
        for terminal in [built, restored] {
            feed(terminal, "\u{1B}c")
            XCTAssertTrue(terminal.isModeSet(2027))
        }
    }

    /// 默认一条未知 OSC 都不报（iOS 不要）。
    func testUnknownOSCIsNotReportedByDefault() {
        let terminal = makeTerminal()
        let log = recording(terminal)
        feed(terminal, "\u{1B}]6973;S;1a2b\u{07}\u{1B}]1337;SetMark\u{07}")
        XCTAssertFalse(log.events.contains { if case .unknownOSC = $0 { return true } else { return false } })
    }

    /// 标记跟着内容滚：后面又来了几屏输出，起止之间读到的还是那一段；软折行拼回一行。
    func testMarkersFollowScrollingAndUnwrapSoftWraps() {
        let terminal = makeTerminal(cols: 20, rows: 5)
        feed(terminal, "before\r\n")
        let start = terminal.markCursor()
        feed(terminal, "a very long line that wraps around the twenty columns\r\nshort\r\n")
        let end = terminal.markCursor()
        for index in 0..<50 { feed(terminal, "later \(index)\r\n") }

        guard let start, let end else { return XCTFail("打不了标记") }
        let output = terminal.text(from: start, to: end)
        XCTAssertEqual(output.text, "a very long line that wraps around the twenty columns\nshort")
        XCTAssertFalse(output.truncated)
    }

    /// 没有结束标记 = 还在跑：读到光标为止；光标停在行中间时这一行也算。
    func testOpenEndedTextReadsUpToCursor() {
        let terminal = makeTerminal()
        guard let start = terminal.markCursor() else { return XCTFail("打不了标记") }
        feed(terminal, "done 1\r\nPassword: ")
        XCTAssertEqual(terminal.text(from: start, to: nil).text, "done 1\nPassword:")
        feed(terminal, "\r\n")
        XCTAssertEqual(terminal.text(from: start, to: nil).text, "done 1\nPassword:")
    }

    /// 起点所在的行没了（RIS 清掉了整屏）：从现存的第一行读起，并标截断。
    func testLostStartMarkerReadsFromTopAndReportsTruncation() {
        let terminal = makeTerminal()
        feed(terminal, "gone\r\n")
        guard let start = terminal.markCursor() else { return XCTFail("打不了标记") }
        feed(terminal, "also gone\r\n\u{1B}cfresh\r\n")
        let output = terminal.text(from: start, to: nil)
        XCTAssertEqual(output.text, "fresh")
        XCTAssertTrue(output.truncated)
    }

    // MARK: 读屏

    /// 宽字符后面不带 NUL（旧引擎的读屏会带），制表符读出来是空格。
    func testRecentLinesReadsPlainTextWithoutNULs() {
        let terminal = makeTerminal()
        feed(terminal, "line1 中文 abc\r\ntab\there\r\n\r\nlast")
        let result = terminal.recentLines(10)
        XCTAssertEqual(result.lines, ["line1 中文 abc", "tab     here", "", "last"])
        XCTAssertFalse(result.truncated)
        XCTAssertFalse(result.lines.joined().unicodeScalars.contains { $0.value == 0 })
    }

    func testRecentLinesTakesTheTailAndReportsTruncation() {
        let terminal = makeTerminal(cols: 20, rows: 5)
        for index in 0..<40 { feed(terminal, "row \(index)\r\n") }
        let result = terminal.recentLines(3)
        XCTAssertEqual(result.lines, ["row 37", "row 38", "row 39"])
        XCTAssertTrue(result.truncated)
    }

    /// 内容后面挂着好几屏空行（`clear` 之后、全屏程序退出之后）也要读得到内容。
    func testRecentLinesSkipsABlankTailLongerThanTheWindow() {
        let terminal = makeTerminal(cols: 20, rows: 5)
        feed(terminal, "kept 1\r\nkept 2")
        feed(terminal, String(repeating: "\r\n", count: 60))
        let result = terminal.recentLines(2)
        XCTAssertEqual(result.lines, ["kept 1", "kept 2"])
        XCTAssertFalse(result.truncated)
    }

    func testRecentLinesOnAnEmptyTerminal() {
        let result = makeTerminal().recentLines(5)
        XCTAssertEqual(result.lines, [])
        XCTAssertFalse(result.truncated)
    }

    // MARK: 模式与标志

    func testKittyKeyboardFlagsAndBracketedPaste() {
        let terminal = makeTerminal()
        XCTAssertEqual(terminal.kittyKeyboardFlags, 0)
        XCTAssertFalse(terminal.bracketedPasteMode)
        feed(terminal, "\u{1B}[>1u\u{1B}[?2004h")
        XCTAssertEqual(terminal.kittyKeyboardFlags, 1)
        XCTAssertTrue(terminal.bracketedPasteMode)
        feed(terminal, "\u{1B}[<u\u{1B}[?2004l")
        XCTAssertEqual(terminal.kittyKeyboardFlags, 0)
        XCTAssertFalse(terminal.bracketedPasteMode)
    }

    // MARK: 就地还原

    /// 还原之后对象还是同一个：事件处理闭包照常收事件，内容换成快照里的。
    func testRestoreReplacesStateInPlaceAndKeepsHandlers() throws {
        let source = makeTerminal(cols: 30, rows: 6)
        feed(source, "history 1\r\nhistory 2\r\n\u{1B}[?1049halt screen")
        let snapshot = try source.snapshot()

        let terminal = makeTerminal(cols: 80, rows: 24)
        XCTAssertFalse(terminal.hasContent)
        let log = recording(terminal)
        feed(terminal, "will be replaced")
        try terminal.restore(snapshot: snapshot)

        XCTAssertTrue(terminal.hasContent)
        XCTAssertEqual(terminal.size.cols, 30)
        XCTAssertEqual(terminal.size.rows, 6)
        XCTAssertTrue(terminal.isOnAlternateScreen)
        XCTAssertEqual(terminal.viewportText(), source.viewportText())

        feed(terminal, "\u{1B}[?1049l\u{1B}]7501;state=working\u{07}")
        XCTAssertEqual(terminal.recentLines(5).lines, ["history 1", "history 2"])
        XCTAssertEqual(log.events.count, 1, "还原后事件回调要还在")
    }

    func testRestoreRejectsGarbage() {
        let terminal = makeTerminal()
        feed(terminal, "keep me")
        XCTAssertThrowsError(try terminal.restore(snapshot: Data("not a snapshot".utf8)))
        XCTAssertEqual(terminal.recentLines(1).lines, ["keep me"], "还原失败时原来的内容不动")
    }

    func testScrollbackLimitsFollowTheLineCount() {
        XCTAssertEqual(TerminalScrollbackLimits(lines: 3_000).bytes, 10_000_000, "行数少时字节上限不低于 10 MB")
        XCTAssertEqual(TerminalScrollbackLimits(lines: 100_000).bytes, 100_000_000)
        XCTAssertEqual(TerminalScrollbackLimits(lines: -5).lines, 0)
        let options = TerminalScrollbackLimits(lines: 20_000).shadowOptions
        XCTAssertEqual(options.scrollbackLines, 20_000)
        XCTAssertEqual(options.scrollbackBytes, 20_000_000)
    }
}
