import XCTest
@testable import uTerm

/// 终端快照的保真度。原来核的是旧引擎的本地补丁 #6（`snapshotSequence`：把终端状态重新编成一段 VT 流）；
/// 现在快照是影子终端的二进制快照（`ShadowTerminal.snapshot()`，libghostty-vt 的格式），远控镜像和 holder 检查点都用它。
///
/// 远控时手机接入一条正在跑的会话：Mac 端发一份快照，之后只转发原始字节。所以快照必须让手机端的终端与 Mac 端一致，
/// 并且之后的字节在两边产生同样的结果。
///
/// 语料是 `Support/Fixtures/TerminalCorpus/record.py` 在 100×30 伪终端里录的真实程序输出
/// （shell / vim / htop / less / 混合）。每个切点：终端 A 喂到切点 → 快照还原成全新的终端 B → 比一次；再把剩余字节
/// 喂给两边、再比一次。看不见的状态（制表位、字符集、鼠标编码……）在第二次比对时暴露。
/// 比的是 `stateDifferences`：尺寸、光标、备用屏、标题、总行数、视口文字，再加从状态重新生成的回放流（带每格的颜色与属性、模式）。
///
/// 和旧快照的两点不同：二进制快照带着没走完的半个转义序列 / 半个 UTF-8 字符，任何字节位置都能拍（旧的要等到解析边界）；
/// 带整段回滚，不截到最近 1000 行。
final class TerminalSnapshotTests: XCTestCase {

    private let options = TerminalScrollbackLimits(lines: 2_000).shadowOptions

    private func makeTerminal(cols: UInt16 = 100, rows: UInt16 = 30) -> ShadowTerminal {
        ShadowTerminal(cols: cols, rows: rows, options: options)
    }

    private func restored(from terminal: ShadowTerminal) throws -> ShadowTerminal {
        try ShadowTerminal(snapshot: terminal.snapshot(), options: options)
    }

    private func feed(_ terminal: ShadowTerminal, _ text: String) {
        terminal.feed(Data(text.utf8))
    }

    /// 在 `cut`（任意字节位置）拍快照往返一次。返回两次比对的差异（空 = 一致）。
    private func roundTrip(_ data: Data, cut: Int) throws -> (immediate: [String: String], continued: [String: String]) {
        let a = makeTerminal()
        a.feed(data.prefix(cut))
        let b = try restored(from: a)
        let immediate = a.stateDifferences(from: b)
        let rest = data.dropFirst(cut)
        a.feed(Data(rest))
        b.feed(Data(rest))
        return (immediate, a.stateDifferences(from: b))
    }

    // MARK: - 真实程序语料

    func test_corpus_snapshots_reproduce_state_and_continue_identically() throws {
        for name in ["shell", "vim", "htop", "less", "mixed"] {
            let data = try TerminalCorpus.bytes(name)
            let cuts = 16
            for i in 1...cuts {
                let cut = data.count * i / (cuts + 1)
                let result = try roundTrip(data, cut: cut)
                XCTAssertEqual(result.immediate, [:], "\(name) 切点 \(cut)：快照后立即不一致")
                XCTAssertEqual(result.continued, [:], "\(name) 切点 \(cut)：续播到结尾不一致")
            }
        }
    }

    /// 切点落在 DEC 画线字符集生效期间：字符集不复原的话，之后的 `lqqk` 不会画成 `┌──┐`。
    func test_dec_line_drawing_charset_survives_snapshot() throws {
        let data = try TerminalCorpus.bytes("mixed")
        let bytes = [UInt8](data)
        let designate: [UInt8] = [0x1b, 0x28, 0x30], restore: [UInt8] = [0x1b, 0x28, 0x42]
        let start = try XCTUnwrap(firstIndex(of: designate, in: bytes, from: 0))
        let end = try XCTUnwrap(firstIndex(of: restore, in: bytes, from: start))
        var checked = 0
        for cut in (start + designate.count)...end {
            checked += 1
            let result = try roundTrip(data, cut: cut)
            XCTAssertEqual(result.immediate, [:], "画线字符集期间切点 \(cut)：快照后立即不一致")
            XCTAssertEqual(result.continued, [:], "画线字符集期间切点 \(cut)：续播不一致")
        }
        XCTAssertGreaterThan(checked, 10)
    }

    private func firstIndex(of pattern: [UInt8], in data: [UInt8], from: Int) -> Int? {
        guard data.count >= pattern.count else { return nil }
        return (from...(data.count - pattern.count)).first { Array(data[$0..<($0 + pattern.count)]) == pattern }
    }

    // MARK: - 拍快照的时机

    /// 旧快照只能在解析边界上拍（半个转义序列 / 半个 UTF-8 字符时要等）。二进制快照没有这个限制：停在半个序列、
    /// 半个字符里照样拍，后半截到了接得上。
    func test_snapshot_mid_escape_sequence_and_mid_utf8_continues_correctly() throws {
        let text = "ok \u{1b}[38;2;215;119;87m橙色\u{1b}[0m \u{1b}]2;标题\u{07}中文 end"
        let bytes = Data(text.utf8)
        let whole = makeTerminal()
        whole.feed(bytes)
        for cut in 1..<bytes.count {
            let a = makeTerminal()
            a.feed(bytes.prefix(cut))
            let b = try restored(from: a)
            b.feed(Data(bytes.dropFirst(cut)))
            XCTAssertEqual(b.stateDifferences(from: whole), [:], "切在第 \(cut) 字节")
        }
        XCTAssertEqual(whole.title, "标题")
        XCTAssertEqual(whole.recentLines(1).lines, ["ok 橙色 中文 end"])
    }

    // MARK: - 语料里没有覆盖到的状态

    /// 左右边距、原点模式、自定义制表位、SGR 鼠标、Kitty 键盘、隐藏光标、插入模式、标题、
    /// G1 画线字符集 + SO、卷曲彩色下划线、真彩色，以及停在「待折行」的行末宽字符。
    func test_less_common_state_round_trips() throws {
        let a = makeTerminal()
        let setup = [
            "\u{1b}[?69h\u{1b}[5;60s",          // 左右边距
            "\u{1b}[3;20r\u{1b}[?6h",           // 滚动区域 + 原点模式
            "\u{1b}[3g\u{1b}[1;5H\u{1b}H\u{1b}[1;13H\u{1b}H",  // 自定义制表位
            "\u{1b}[?1002h\u{1b}[?1006h",       // 按键拖动追踪 + SGR 编码
            "\u{1b}[=5;1u",                     // Kitty 键盘标志位
            "\u{1b}[?25l\u{1b}[4h",             // 隐藏光标、插入模式
            "\u{1b}[?2004h",                    // 括号粘贴
            "\u{1b}]2;远控标题\u{7}",
            "\u{1b})0\u{0e}",                   // G1 = DEC 画线，SO 切过去
            "\u{1b}[4:3;58;2;255;0;0;38;2;10;200;30mlqk\u{1b}[0m",
            "\u{1b}[?6l\u{1b}[?69l\u{1b}[r\u{1b}[30;99H中",      // 行末宽字符，停在待折行
        ].joined()
        feed(a, setup)
        let b = try restored(from: a)
        XCTAssertEqual(a.stateDifferences(from: b), [:])
        XCTAssertEqual(b.title, "远控标题")
        XCTAssertEqual(b.kittyKeyboardFlags, a.kittyKeyboardFlags)
        XCTAssertNotEqual(b.kittyKeyboardFlags, 0)
        XCTAssertFalse(b.cursor.visible)
        XCTAssertTrue(b.cursor.pendingWrap, "停在待折行")
        XCTAssertTrue(b.bracketedPasteMode)
        for mode in [1002, 1006] as [UInt16] {
            XCTAssertTrue(b.isModeSet(mode), "模式 \(mode)")
        }

        let more = "\u{1b}[5;1Hqqq\tx\u{0f}abc\u{1b}[?6h\u{1b}[1;1Hend"
        feed(a, more)
        feed(b, more)
        XCTAssertEqual(a.stateDifferences(from: b), [:])
    }

    /// 先按 80 列创建再改宽（Mac 端终端就是这样：按初始尺寸建，随窗口改尺寸）：备用屏的制表位此刻不是当前缓冲区。
    /// 快照必须把它也带过去，否则之后进入 vim 等全屏程序时 `\t` 的落点不同。
    func test_inactive_alternate_buffer_tab_stops_after_resize() throws {
        let a = makeTerminal(cols: 80, rows: 24)
        a.resize(cols: 130, rows: 40)
        a.feed(try TerminalCorpus.bytes("shell"))
        let b = try restored(from: a)
        XCTAssertEqual(a.stateDifferences(from: b), [:])

        let enterAltAndTab = "\u{1b}[?1049h\u{1b}[H\tA\t\t\tB\t\t\t\t\t\t\t\t\t\t\t\tC"
        feed(a, enterAltAndTab)
        feed(b, enterAltAndTab)
        XCTAssertEqual(a.stateDifferences(from: b), [:])
        XCTAssertEqual(a.character(col: 8, row: 0), "A", "第一个制表位在第 9 列")
        XCTAssertEqual(b.character(col: 8, row: 0), "A")
        XCTAssertEqual(b.viewportText(), a.viewportText())
    }

    /// 先改尺寸（重排）再拍快照。远控时手机每次转屏、弹键盘都会走到这里：Mac 按新尺寸重排后立即重发快照。
    func test_snapshot_after_reflow_to_other_sizes() throws {
        for name in ["shell", "mixed", "vim"] {
            let data = try TerminalCorpus.bytes(name)
            for (cols, rows) in [(50, 18), (40, 30), (90, 25), (120, 40), (30, 10)] as [(UInt16, UInt16)] {
                let a = makeTerminal(cols: 64, rows: 20)
                a.feed(data)
                a.resize(cols: cols, rows: rows)
                let b = try restored(from: a)
                XCTAssertEqual(b.size.cols, Int(cols))
                XCTAssertEqual(b.size.rows, Int(rows))
                XCTAssertEqual(a.stateDifferences(from: b), [:], "\(name) 64×20 → \(cols)×\(rows)")
                // 之后的输出两边一样。
                let more = "\r\nafter resize \u{1b}[1mbold\u{1b}[0m\r\n"
                feed(a, more)
                feed(b, more)
                XCTAssertEqual(a.stateDifferences(from: b), [:], "\(name) 64×20 → \(cols)×\(rows)，续播")
            }
        }
    }

    /// 上千行彩色历史：快照带整段回滚（旧快照只带最近 1000 行），还原出来的历史与 A 逐行一致。
    func test_large_history_round_trips() throws {
        let shell = try TerminalCorpus.bytes("shell")
        let a = makeTerminal()
        for _ in 0..<40 { a.feed(shell) }
        XCTAssertGreaterThan(a.totalRows, 1_000, "历史不足 1000 行，测不到长历史")
        let b = try restored(from: a)
        XCTAssertEqual(b.totalRows, a.totalRows, "整段回滚都在")
        XCTAssertEqual(a.stateDifferences(from: b), [:])
        let lines = a.totalRows
        XCTAssertEqual(b.recentLines(lines).lines, a.recentLines(lines).lines, "历史逐行一致")
    }

    /// 回滚上限是终端选项，不在快照里：还原进上限更小的终端，历史按那边的上限裁（镜像快照要按「最近 N 行」裁的话
    /// 就是这么做），留下的是最新的那部分。
    func test_restoring_into_a_smaller_scrollback_limit_keeps_the_newest_history() throws {
        let a = makeTerminal()
        feed(a, (0..<3_000).map { "row \($0)\r\n" }.joined())
        let small = try ShadowTerminal(snapshot: a.snapshot(), options: TerminalScrollbackLimits(lines: 500).shadowOptions)
        XCTAssertLessThan(small.totalRows, a.totalRows)
        XCTAssertLessThanOrEqual(small.totalRows, 500 + 30 + 200, "按页裁：留下的行数在上限附近")
        XCTAssertEqual(small.viewportText(), a.viewportText(), "视口不受影响")
        XCTAssertEqual(small.recentLines(100).lines, a.recentLines(100).lines, "留下的是最新的历史")
        XCTAssertLessThan(try small.snapshot().count, try a.snapshot().count, "再拍一张就小了")
    }

    // MARK: - 快照 → 回放流（画面那一侧吃的是 VT）

    /// surface 吃不了二进制快照：泵把快照变成一段 VT（`ShadowTerminal.replay(fromSnapshot:)`）灌进去。
    /// 这段流喂进一台同样大小的新终端，视口、光标、备用屏要和源终端一样。
    func test_replay_stream_reproduces_the_screen_in_a_fresh_terminal() throws {
        for name in ["shell", "vim", "htop", "less", "mixed"] {
            let data = try TerminalCorpus.bytes(name)
            for i in 1...8 {
                let cut = data.count * i / 9
                let a = makeTerminal()
                a.feed(data.prefix(cut))
                let replay = try ShadowTerminal.replay(fromSnapshot: a.snapshot())
                XCTAssertTrue(replay.verified, "\(name) 切点 \(cut)：回放流自查没过")
                let b = makeTerminal()
                b.feed(replay.stream)
                XCTAssertEqual(b.mirrorDifferences(from: a, includingHistory: false), [:], "\(name) 切点 \(cut)")
            }
        }
    }
}
