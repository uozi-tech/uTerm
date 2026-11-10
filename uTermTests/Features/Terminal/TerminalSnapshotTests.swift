// 【迁移中，暂未编译】这份用例还依赖 SwiftTerm 或已经删掉的 SwiftTerm 时代类型，等改写到 Ghostty + 影子终端
// （`ShadowTerminal`）上的同一条行为。改写完把这一对 `#if UTERM_LEGACY_SWIFTTERM_TESTS` / `#endif` 去掉。
// 清单与进度见 docs/ghostty-eval/migration-log.md「测试改写」。
#if UTERM_LEGACY_SWIFTTERM_TESTS
import XCTest
import SwiftTerm

/// 终端快照（vendored SwiftTerm 补丁，见 vendor/SwiftTerm/UTERM-PATCHES.md 第 6 条）的保真度。
///
/// 远控时手机接入一条正在跑的会话：Mac 端发一份快照（`snapshotSequence`），之后只转发原始字节。
/// 所以快照必须让手机端的终端与 Mac 端**逐格**一致，并且之后的字节在两边产生同样的结果。
///
/// 语料是 `Support/Fixtures/TerminalCorpus/record.py` 在 100×30 伪终端里录的真实程序输出
/// （shell / vim / htop / less / 混合）。每个切点：终端 A 喂到切点（推进到 `isAtSnapshotBoundary`，
/// 与生产上拍快照的判据相同）→ 快照喂给全新的终端 B → 比指纹；再把剩余字节喂给两边、再比一次。
/// 看不见的状态（制表位、字符集、鼠标编码……）在第二次比对时暴露。
final class TerminalSnapshotTests: XCTestCase {

    private final class SilentDelegate: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    // Terminal 只弱持有 delegate。
    private let delegate = SilentDelegate()

    private func makeTerminal() -> Terminal {
        Terminal(delegate: delegate, options: TerminalOptions(cols: 100, rows: 30, scrollback: 2000))
    }

    private func corpus(_ name: String) throws -> [UInt8] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "terminal-corpus-\(name)", withExtension: "bin"),
                                "缺语料 terminal-corpus-\(name).bin，用 record.py 重新录制")
        return [UInt8](try Data(contentsOf: url))
    }

    /// 在 `cut` 附近拍快照往返一次。返回实际切点与两次比对的差异（空 = 一致）。
    private func roundTrip(_ data: [UInt8], cut: Int) -> (cut: Int, immediate: [String: String], continued: [String: String]) {
        let a = makeTerminal()
        var p = cut
        a.feed(byteArray: Array(data[0..<p]))
        while p < data.count && !a.isAtSnapshotBoundary {
            a.feed(byteArray: [data[p]])
            p += 1
        }
        let b = makeTerminal()
        b.feed(byteArray: a.snapshotSequence())
        let immediate = a.snapshotFingerprint().differences(from: b.snapshotFingerprint())
        let rest = Array(data[p...])
        a.feed(byteArray: rest)
        b.feed(byteArray: rest)
        let continued = a.snapshotFingerprint().differences(from: b.snapshotFingerprint())
        return (p, immediate, continued)
    }

    // MARK: - 真实程序语料

    func test_corpus_snapshots_reproduce_state_and_continue_identically() throws {
        for name in ["shell", "vim", "htop", "less", "mixed"] {
            let data = try corpus(name)
            let cuts = 16
            for i in 1...cuts {
                let result = roundTrip(data, cut: data.count * i / (cuts + 1))
                XCTAssertEqual(result.immediate, [:], "\(name) 切点 \(result.cut)：快照后立即不一致")
                XCTAssertEqual(result.continued, [:], "\(name) 切点 \(result.cut)：续播到结尾不一致")
            }
        }
    }

    /// 切点落在 DEC 画线字符集生效期间：字符集不复原的话，之后的 `lqqk` 不会画成 `┌──┐`。
    func test_dec_line_drawing_charset_survives_snapshot() throws {
        let data = try corpus("mixed")
        let designate: [UInt8] = [0x1b, 0x28, 0x30], restore: [UInt8] = [0x1b, 0x28, 0x42]
        let start = try XCTUnwrap(firstIndex(of: designate, in: data, from: 0))
        let end = try XCTUnwrap(firstIndex(of: restore, in: data, from: start))
        var checked = 0
        for cut in (start + designate.count)...end {
            let result = roundTrip(data, cut: cut)
            guard result.cut == cut else { continue }
            checked += 1
            XCTAssertEqual(result.continued, [:], "画线字符集期间切点 \(cut)：续播不一致")
        }
        XCTAssertGreaterThan(checked, 10)
    }

    private func firstIndex(of pattern: [UInt8], in data: [UInt8], from: Int) -> Int? {
        guard data.count >= pattern.count else { return nil }
        return (from...(data.count - pattern.count)).first { Array(data[$0..<($0 + pattern.count)]) == pattern }
    }

    // MARK: - 拍快照的时机

    func test_boundary_rejects_partial_escape_sequence_and_partial_utf8() {
        let t = makeTerminal()
        XCTAssertTrue(t.isAtSnapshotBoundary)

        t.feed(byteArray: Array("\u{1b}[3".utf8))
        XCTAssertFalse(t.isAtSnapshotBoundary, "转义序列只到一半")
        t.feed(byteArray: Array("1m".utf8))
        XCTAssertTrue(t.isAtSnapshotBoundary)

        let wide = Array("中".utf8)
        t.feed(byteArray: Array(wide[0..<2]))
        XCTAssertFalse(t.isAtSnapshotBoundary, "UTF-8 字符只到一半，SwiftTerm 暂存着前两个字节")
        t.feed(byteArray: [wide[2]])
        XCTAssertTrue(t.isAtSnapshotBoundary)
    }

    // MARK: - 语料里没有覆盖到的状态

    /// 左右边距、原点模式、自定义制表位、SGR 鼠标、Kitty 键盘、隐藏光标、插入模式、标题、
    /// G1 画线字符集 + SO、卷曲彩色下划线、真彩色，以及停在「待折行」的行末宽字符。
    func test_less_common_state_round_trips() {
        let a = makeTerminal()
        let setup = [
            "\u{1b}[?69h\u{1b}[5;60s",          // 左右边距
            "\u{1b}[3;20r\u{1b}[?6h",           // 滚动区域 + 原点模式
            "\u{1b}[3g\u{1b}[1;5H\u{1b}H\u{1b}[1;13H\u{1b}H",  // 自定义制表位
            "\u{1b}[?1002h\u{1b}[?1006h",       // 按键拖动追踪 + SGR 编码
            "\u{1b}[=5;1u",                     // Kitty 键盘标志位
            "\u{1b}[?25l\u{1b}[4h",             // 隐藏光标、插入模式
            "\u{1b}]2;远控标题\u{7}",
            "\u{1b})0\u{0e}",                   // G1 = DEC 画线，SO 切过去
            "\u{1b}[4:3;58;2;255;0;0;38;2;10;200;30mlqk\u{1b}[0m",
            "\u{1b}[?6l\u{1b}[?69l\u{1b}[r\u{1b}[30;99H中",      // 行末宽字符，停在待折行
        ].joined()
        a.feed(text: setup)
        XCTAssertTrue(a.isAtSnapshotBoundary)
        let b = makeTerminal()
        b.feed(byteArray: a.snapshotSequence())
        XCTAssertEqual(a.snapshotFingerprint().differences(from: b.snapshotFingerprint()), [:])

        let more = "\u{1b}[5;1Hqqq\tx\u{0f}abc\u{1b}[?6h\u{1b}[1;1Hend"
        a.feed(text: more)
        b.feed(text: more)
        XCTAssertEqual(a.snapshotFingerprint().differences(from: b.snapshotFingerprint()), [:])
    }

    /// 先按 80 列创建再改宽（Mac 端终端就是这样：初始 80 列，随窗口改尺寸）：备用屏的制表位
    /// 停在旧宽度，而且此刻它不是当前缓冲区。接收端是直接按新宽度创建的，快照必须把它也复原，
    /// 否则之后进入 vim 等全屏程序时 `\t` 的落点不同。
    func test_inactive_alternate_buffer_tab_stops_after_resize() throws {
        let a = Terminal(delegate: delegate, options: TerminalOptions(cols: 80, rows: 24, scrollback: 2000))
        a.resize(cols: 130, rows: 40)
        a.feed(byteArray: try corpus("shell"))
        XCTAssertTrue(a.isAtSnapshotBoundary)
        let b = Terminal(delegate: delegate, options: TerminalOptions(cols: 130, rows: 40, scrollback: 2000))
        b.feed(byteArray: a.snapshotSequence())
        XCTAssertEqual(a.snapshotFingerprint().differences(from: b.snapshotFingerprint()), [:])

        let enterAltAndTab = Array("\u{1b}[?1049h\tA\t\t\tB\t\t\t\t\t\t\t\t\t\t\t\tC".utf8)
        a.feed(byteArray: enterAltAndTab)
        b.feed(byteArray: enterAltAndTab)
        XCTAssertEqual(a.snapshotFingerprint().differences(from: b.snapshotFingerprint()), [:])
    }

    /// 先改尺寸（重排）再拍快照。远控时手机每次转屏、弹键盘都会走到这里：Mac 按新尺寸重排后
    /// 立即重发快照。变窄时重排会切出整行空白的续行（zsh 的 PROMPT_SP 填充），快照必须把它
    /// 也「折」出来，否则少一行、下面整体上移。
    func test_snapshot_after_reflow_to_other_sizes() throws {
        for name in ["shell", "mixed", "vim"] {
            let data = try corpus(name)
            for (cols, rows) in [(50, 18), (40, 30), (90, 25), (120, 40), (30, 10)] {
                let a = Terminal(delegate: delegate, options: TerminalOptions(cols: 64, rows: 20, scrollback: 2000))
                a.feed(byteArray: data)
                a.resize(cols: cols, rows: rows)
                let b = Terminal(delegate: delegate, options: TerminalOptions(cols: cols, rows: rows, scrollback: 2000))
                b.feed(byteArray: a.snapshotSequence())
                XCTAssertEqual(a.snapshotFingerprint().differences(from: b.snapshotFingerprint()), [:],
                               "\(name) 64×20 → \(cols)×\(rows)")
            }
        }
    }

    /// 1000 行彩色历史：快照只带最近 1000 行，接收端的历史与 A 的最后 1000 行逐行一致。
    func test_large_history_round_trips() throws {
        let shell = try corpus("shell")
        let a = makeTerminal()
        for _ in 0..<60 { a.feed(byteArray: shell) }
        XCTAssertGreaterThan(a.snapshotFingerprint(historyLines: .max).categories["history"]?.count ?? 0, 1000,
                             "历史不足 1000 行，测不到截断")
        let b = makeTerminal()
        b.feed(byteArray: a.snapshotSequence(scrollbackLimit: 1000))
        XCTAssertEqual(a.snapshotFingerprint(historyLines: 1000).differences(from: b.snapshotFingerprint(historyLines: 1000)), [:])
        XCTAssertEqual(b.snapshotFingerprint().categories["history"]?.count, 1000)
    }
}
#endif
