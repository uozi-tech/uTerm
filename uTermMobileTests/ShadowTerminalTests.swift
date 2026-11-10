import Foundation
import XCTest
@testable import uTermMobile

/// 影子终端（`uTerm/Features/Terminal/Shadow/ShadowTerminal.swift`，libghostty-vt）：喂字节、读状态、resize、二进制快照往返，
/// 以及快照 → 回放流（灌进一个**用过的**终端后，那个终端要和源终端一样，并且能从任意字节处接着喂）。
/// 不建 surface、不要窗口，纯逻辑。surface 那一侧（回放进真的 GhosttyKit surface）在 `GhosttyBackgroundTests`。
final class ShadowTerminalTests: XCTestCase {
    private func options() -> ShadowTerminal.Options {
        ShadowTerminal.Options(scrollbackLines: 10_000, scrollbackBytes: 10_000_000)
    }

    /// 接收端先弄脏：有旧内容、停在备用屏、还卡在半个 OSC 里。
    private func dirtyTerminal(cols: UInt16, rows: UInt16) -> ShadowTerminal {
        let terminal = ShadowTerminal(cols: cols, rows: rows, options: options())
        terminal.feed(Data("old content\r\n\u{1B}[31mred\u{1B}[?1049h\u{1B}[5;5Halt\u{1B}]11;#ff0000\u{07}\u{1B}]0;stale title".utf8))
        return terminal
    }

    private func roundTrip(_ stream: Data, cut: Int, cols: UInt16 = 58, rows: UInt16 = 30,
                           file: StaticString = #filePath, line: UInt = #line) throws {
        let source = ShadowTerminal(cols: cols, rows: rows, options: options())
        source.feed(stream.prefix(cut))
        let replay = try ShadowTerminal.replayStream(fromSnapshot: source.snapshot())
        let sink = dirtyTerminal(cols: cols, rows: rows)
        sink.feed(replay)
        XCTAssertEqual(sink.viewportText(), source.viewportText(), "回放后视口不同（cut=\(cut)）", file: file, line: line)
        XCTAssertEqual(sink.totalRows, source.totalRows, "回放后总行数不同（cut=\(cut)）", file: file, line: line)
        XCTAssertEqual(sink.title, source.title, "回放后标题不同（cut=\(cut)）", file: file, line: line)
        XCTAssertEqual(sink.isOnAlternateScreen, source.isOnAlternateScreen, file: file, line: line)
        // 续播：隐藏状态（模式、存的光标、备用屏底下的主屏、半个序列）这时才显形。
        let rest = Data(stream.suffix(from: cut))
        source.feed(rest)
        sink.feed(rest)
        XCTAssertEqual(sink.viewportText(), source.viewportText(), "续播后视口不同（cut=\(cut)）", file: file, line: line)
        XCTAssertEqual(sink.title, source.title, "续播后标题不同（cut=\(cut)）", file: file, line: line)
        XCTAssertEqual(sink.isOnAlternateScreen, source.isOnAlternateScreen, file: file, line: line)
    }

    /// 一份混合语料：带色历史（软折行、中文、emoji）、带标题的同步帧、全屏程序进出备用屏。
    private func corpus() -> Data {
        var text = ""
        for i in 0..<300 {
            text += "\u{1B}[3\(i % 7 + 1)m\(i) INFO request id=\(i * 7919) \u{1B}[1;4mpath\u{1B}[0m=/api/v1/items/\(i % 977) 说明 ok 👍🏽 很长的一行会折到下一行去\u{1B}[0m\r\n"
        }
        for n in 0..<20 {
            text += "\u{1B}]0;✳ 第 \(n) 帧\u{07}\u{1B}[?2026h\u{1B}[2A\r\u{1B}[2K\u{1B}[38;2;215;119;87m✻ Thinking…\u{1B}[0m (\(n)s)\r\n\u{1B}[2K│ > \u{1B}[7m \u{1B}[0m\r\n\u{1B}[?2026l"
        }
        text += "\u{1B}7\u{1B}[?1049h\u{1B}[?1h\u{1B}[3;20r"
        for row in 1...20 { text += "\u{1B}[\(row);1H\u{1B}[2K\u{1B}[4\(row % 7 + 1)m~ 第 \(row) 行\u{1B}[0m" }
        text += "\u{1B}[r\u{1B}[?1l\u{1B}[?1049l\u{1B}8$ echo done\r\ndone\r\n$ "
        return Data(text.utf8)
    }

    // MARK: 读状态

    func testFeedThenReadTextCursorAndScreen() {
        let terminal = ShadowTerminal(cols: 40, rows: 10, options: options())
        XCTAssertEqual(terminal.size.cols, 40)
        XCTAssertEqual(terminal.size.rows, 10)
        terminal.feed(Data("$ ls\r\n\u{1B}[34mdocs\u{1B}[0m  中文.txt\r\n$ ".utf8))
        let lines = terminal.viewportText().split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(lines.count, 10, "可见区一行一段")
        XCTAssertEqual(Array(lines.prefix(3)), ["$ ls", "docs  中文.txt", "$"], "纯文本不带转义，行尾空白去掉")
        XCTAssertEqual(terminal.cursor, ShadowTerminal.Cursor(x: 2, y: 2, pendingWrap: false, visible: true))
        XCTAssertFalse(terminal.isOnAlternateScreen)
        XCTAssertEqual(terminal.totalRows, 10)

        // 备用屏：进去是空屏，出来主屏原样；光标可见性跟 DECTCEM。
        terminal.feed(Data("\u{1B}[?1049h\u{1B}[?25l\u{1B}[5;7Hvim".utf8))
        XCTAssertTrue(terminal.isOnAlternateScreen)
        XCTAssertEqual(terminal.cursor, ShadowTerminal.Cursor(x: 9, y: 4, pendingWrap: false, visible: false))
        XCTAssertFalse(terminal.viewportText().contains("docs"))
        terminal.feed(Data("\u{1B}[?25h\u{1B}[?1049l".utf8))
        XCTAssertFalse(terminal.isOnAlternateScreen)
        XCTAssertTrue(terminal.viewportText().contains("docs  中文.txt"))
        XCTAssertEqual(terminal.cursor, ShadowTerminal.Cursor(x: 2, y: 2, pendingWrap: false, visible: true))

        // 写满一行：光标停在最后一格、悬着折行。
        terminal.feed(Data(("\r" + String(repeating: "x", count: 40)).utf8))
        XCTAssertEqual(terminal.cursor, ShadowTerminal.Cursor(x: 39, y: 2, pendingWrap: true, visible: true))
        XCTAssertEqual(terminal.totalFedBytes, 0 + "$ ls\r\n\u{1B}[34mdocs\u{1B}[0m  中文.txt\r\n$ ".utf8.count
            + "\u{1B}[?1049h\u{1B}[?25l\u{1B}[5;7Hvim".utf8.count + "\u{1B}[?25h\u{1B}[?1049l".utf8.count + 41)
    }

    /// 回滚上限显式设：行数管得住，超出的历史被裁掉；只按字节限时留得更多。
    func testScrollbackLimitsAreHonoured() {
        let limited = ShadowTerminal(cols: 40, rows: 10, options: .init(scrollbackLines: 500, scrollbackBytes: 10_000_000))
        let roomy = ShadowTerminal(cols: 40, rows: 10, options: .init(scrollbackLines: nil, scrollbackBytes: 10_000_000))
        var text = ""
        for i in 0..<5000 { text += "line \(i)\r\n" }
        limited.feed(Data(text.utf8))
        roomy.feed(Data(text.utf8))
        XCTAssertEqual(roomy.totalRows, 5001, "只按字节限（10 MB）时 5000 行都在")
        // 按页裁：留下的行数在上限附近（实测 329），不是正好 500。
        XCTAssertGreaterThan(limited.totalRows, 100)
        XCTAssertLessThan(limited.totalRows, 1200, "500 行的上限按页裁，留下的不该多出几页")
        XCTAssertTrue(limited.viewportText().contains("line 4999"))
    }

    // MARK: resize

    /// 改宽度：软折行的行跟着重排，改回来文字原样；尺寸与光标跟着走。相同尺寸是空操作。
    func testResizeReflowsAndRestores() {
        let terminal = ShadowTerminal(cols: 40, rows: 8, options: options())
        let long = String(repeating: "abcdefghij", count: 6)   // 60 个字符：40 列下折成两行
        terminal.feed(Data("first\r\n\(long)\r\nlast".utf8))
        let before = terminal.viewportText()
        XCTAssertEqual(Array(before.split(separator: "\n", omittingEmptySubsequences: false).prefix(4)).map(String.init),
                       ["first", String(long.prefix(40)), String(long.suffix(20)), "last"])
        let rowsBefore = terminal.totalRows

        terminal.resize(cols: 20, rows: 8)
        XCTAssertEqual(terminal.size.cols, 20)
        let narrow = terminal.viewportText().split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertTrue(narrow.contains(String(long.prefix(20))), "变窄后长行按新宽度折：\(narrow)")
        XCTAssertTrue(narrow.contains("last"))

        terminal.resize(cols: 40, rows: 8)
        XCTAssertEqual(terminal.viewportText(), before, "改回原宽度后文字原样")
        XCTAssertEqual(terminal.totalRows, rowsBefore)
        XCTAssertEqual(terminal.cursor.x, 4)

        terminal.resize(cols: 40, rows: 8)   // 相同尺寸
        XCTAssertEqual(terminal.viewportText(), before)
        terminal.resize(cols: 0, rows: 0)    // 无效尺寸不动
        XCTAssertEqual(terminal.size.cols, 40)

        terminal.resize(cols: 40, rows: 4)
        XCTAssertEqual(terminal.size.rows, 4)
        XCTAssertTrue(terminal.viewportText().contains("last"), "变矮后光标所在行仍在可见区")
    }

    // MARK: 二进制快照往返

    /// 快照 → 还原：还原出来的终端和源终端逐格一致，并且能从任意字节处接着喂。
    /// 「逐格」这样核：两边再各拍一张快照，变成回放流（格子内容、样式、超链接、模式、回滚、光标、没走完的半个序列都在里面）
    /// 逐字节相同；另核可见区文字、总行数、光标、是否在备用屏。
    func testSnapshotRoundTripIsCellExact() throws {
        let stream = corpus()
        var generator = SystemRandomNumberGenerator()
        let cuts = (1...10).map { stream.count * $0 / 11 } + (0..<20).map { _ in Int.random(in: 1..<stream.count, using: &generator) }
            + [stream.count]
        for cut in cuts {
            let source = ShadowTerminal(cols: 58, rows: 30, options: options())
            source.feed(stream.prefix(cut))
            let snapshot = try source.snapshot()
            let restored = try ShadowTerminal(snapshot: snapshot, options: options())
            func assertSame(_ stage: String) throws {
                XCTAssertEqual(restored.viewportText(), source.viewportText(), "\(stage)可见区不同（cut=\(cut)）")
                XCTAssertEqual(restored.totalRows, source.totalRows, "\(stage)总行数不同（cut=\(cut)）")
                XCTAssertEqual(restored.cursor, source.cursor, "\(stage)光标不同（cut=\(cut)）")
                XCTAssertEqual(restored.isOnAlternateScreen, source.isOnAlternateScreen, "\(stage)备用屏状态不同（cut=\(cut)）")
                XCTAssertEqual(restored.title, source.title, "\(stage)标题不同（cut=\(cut)）")
                let a = try ShadowTerminal.replayStream(fromSnapshot: restored.snapshot())
                let b = try ShadowTerminal.replayStream(fromSnapshot: source.snapshot())
                XCTAssertEqual(a, b, "\(stage)两边的格子 / 样式 / 模式不是逐字节相同（cut=\(cut)）")
            }
            try assertSame("还原后")
            let rest = Data(stream.suffix(from: cut))
            source.feed(rest)
            restored.feed(rest)
            try assertSame("续播后")
        }
    }

    // MARK: 快照 → 回放流

    /// 带色历史（软折行、中文）+ 带标题的 Claude 帧，切在各种位置（含半个转义序列、半个 UTF-8 字符中间）。
    func testReplayReproducesScrollbackAndClaudeFrames() throws {
        var text = ""
        for i in 0..<400 {
            text += "\u{1B}[3\(i % 7 + 1)m\(i) 2026-11-10 INFO request id=\(i * 7919) path=/api/v1/items/\(i % 977) 说明 ok 很长的一行会折到下一行去\u{1B}[0m\r\n"
        }
        for n in 0..<40 {
            text += "\u{1B}]0;✳ Claude Code · 第 \(n) 帧\u{07}\u{1B}[?2026h\u{1B}[3A\r\u{1B}[2K\u{1B}[38;2;215;119;87m✻ Thinking…\u{1B}[0m (\(n)s)\r\n"
                + "\u{1B}[2K│ > \u{1B}[7m \u{1B}[0m\r\n\u{1B}[2K  ? for shortcuts\u{1B}[?2026l"
        }
        let stream = Data(text.utf8)
        var generator = SystemRandomNumberGenerator()
        let cuts = (1...12).map { stream.count * $0 / 13 } + (0..<24).map { _ in Int.random(in: 1..<stream.count, using: &generator) }
        for cut in cuts { try roundTrip(stream, cut: cut) }
    }

    /// 全屏程序：DECSC 存光标、进备用屏、滚动区域、应用光标键、括号粘贴、鼠标上报；退出后回到主屏。
    func testReplayReproducesAlternateScreenAndSavedCursor() throws {
        var text = "$ ls\r\n\u{1B}[34mdocs\u{1B}[0m  run.sh\r\n$ vim notes.md\r\n"
        text += "\u{1B}[1;31m\u{1B}7\u{1B}[0m"                                   // 带画笔存光标
        text += "\u{1B}[?1049h\u{1B}[?1h\u{1B}[?2004h\u{1B}[?1002h\u{1B}[?1006h\u{1B}[2;20r"
        for row in 1...24 { text += "\u{1B}[\(row);1H\u{1B}[2K\u{1B}[3\(row % 7 + 1)m~ 第 \(row) 行 buffer text\u{1B}[0m" }
        text += "\u{1B}[10;7H\u{1B}]2;notes.md - VIM\u{07}"
        let quit = "\u{1B}[r\u{1B}[?1002l\u{1B}[?1006l\u{1B}[?2004l\u{1B}[?1l\u{1B}[?1049l\u{1B}8after\r\n$ "
        let stream = Data((text + quit).utf8)
        let inAlternate = Data(text.utf8).count
        for cut in [inAlternate, inAlternate - 3, inAlternate / 2, inAlternate + 10, 30] {
            try roundTrip(stream, cut: cut, cols: 80, rows: 24)
        }
    }

    /// 程序改过的颜色跟着回放走；为答查询设的默认颜色不走（否则 surface 的配色会被写死）。
    func testReplayCarriesOnlyProgramSetColors() throws {
        let source = ShadowTerminal(cols: 80, rows: 24, options: options())
        source.setDefaultColors(foreground: (0xD4, 0xD4, 0xD4), background: (0x14, 0x14, 0x14), cursor: (0xAE, 0xAF, 0xAD), dark: true)
        source.feed(Data("plain\r\n".utf8))
        var replay = String(decoding: try ShadowTerminal.replayStream(fromSnapshot: source.snapshot()), as: UTF8.self)
        XCTAssertFalse(replay.contains("\u{1B}]10;rgb"), "默认前景不该进回放流")
        XCTAssertFalse(replay.contains("\u{1B}]11;rgb"), "默认背景不该进回放流")
        XCTAssertFalse(replay.contains("\u{1B}]4;"), "没改过的调色板不该进回放流")
        source.feed(Data("\u{1B}]11;#102030\u{07}\u{1B}]4;1;#aa0000\u{07}".utf8))
        replay = String(decoding: try ShadowTerminal.replayStream(fromSnapshot: source.snapshot()), as: UTF8.self)
        XCTAssertTrue(replay.contains("\u{1B}]11;rgb:10/20/30"), "程序设的背景色要进回放流")
        XCTAssertTrue(replay.contains("\u{1B}]4;1;rgb:aa/00/00"), "程序改的调色板项要进回放流")
        XCTAssertFalse(replay.contains("\u{1B}]4;2;"), "没改的调色板项不该进回放流")
    }

    /// 查询：开关关着不答，开了才答；DA / 光标位置 / 背景色。
    func testRepliesOnlyWhenEnabled() {
        let box = ReplyBox()
        let terminal = ShadowTerminal(cols: 80, rows: 24, options: options())
        terminal.setDefaultColors(foreground: (0xD4, 0xD4, 0xD4), background: (0x14, 0x14, 0x14), cursor: nil, dark: true)
        terminal.setReplyHandler { box.data.append($0) }
        let queries = Data("\u{1B}[3;5H\u{1B}[c\u{1B}[6n\u{1B}]11;?\u{07}".utf8)
        terminal.feed(queries)
        XCTAssertTrue(box.data.isEmpty, "应答关着时不该答")
        terminal.setRepliesEnabled(true)
        terminal.feed(queries)
        XCTAssertEqual(String(decoding: box.data, as: UTF8.self),
                       "\u{1B}[?62;22;52c\u{1B}[3;5R\u{1B}]11;rgb:1414/1414/1414\u{07}")
    }

    /// 回放的开销读数：1 万行回滚（探针里那种洪流），热着连做 5 次。只卡一个很松的上限，读数从日志里取。
    func testReplayCostReadout() throws {
        let terminal = ShadowTerminal(cols: 62, rows: 52, options: options())
        var flood = ""
        for i in 0..<40_000 {
            flood += "\u{1B}[3\(i % 7 + 1)m\(i) 2026-11-10T22:\(i % 60):00Z INFO request id=\(i * 7919) path=/api/v1/items/\(i % 977) 说明 ok\u{1B}[0m\r\n"
        }
        terminal.feed(Data(flood.utf8))
        var totals: [Double] = []
        for run in 0..<5 {
            let started = DispatchTime.now().uptimeNanoseconds
            let replay = try terminal.makeReplay()
            let total = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
            totals.append(total)
            print(String(format: "GHBG replay-cost run=%d rows=%d snapshot=%dB stream=%dB total=%.1fms encode=%.1fms stream=%.1fms verify=%.1fms unwrapped=%@ verified=%@",
                         run, terminal.totalRows, replay.snapshotBytes, replay.stream.count, total,
                         replay.encodeSeconds * 1000, replay.buildSeconds * 1000, replay.verifySeconds * 1000,
                         String(replay.unwrapped), String(replay.verified)))
            XCTAssertTrue(replay.verified)
        }
        XCTAssertLessThan(totals.min() ?? .infinity, 200, "1 万行回滚的回放不该要这么久")
    }

    /// 快照能还原成影子终端，并且还原出来的还能再拍快照（停在半个序列里也行：解码时要显式保留续接字节）。
    func testSnapshotRestoresAndCanBeSnapshottedAgain() throws {
        let source = ShadowTerminal(cols: 60, rows: 20, options: options())
        source.feed(Data("line one\r\n\u{1B}[32mgreen\u{1B}[0m\r\n\u{1B}]0;half a tit".utf8))
        let restored = try ShadowTerminal(snapshot: source.snapshot(), options: options())
        XCTAssertEqual(restored.viewportText(), source.viewportText())
        let again = try ShadowTerminal(snapshot: restored.snapshot(), options: options())
        let rest = Data("le\u{07}tail\r\n".utf8)
        source.feed(rest)
        again.feed(rest)
        XCTAssertEqual(again.title, "half a title")
        XCTAssertEqual(again.viewportText(), source.viewportText())
    }
}

private nonisolated final class ReplyBox: @unchecked Sendable {
    var data = Data()
}
