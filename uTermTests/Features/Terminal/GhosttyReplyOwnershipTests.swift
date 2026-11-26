import AppKit
import XCTest
@testable import uTerm

/// 发给程序的字节（PTY 的输入方向）里只能有按键和查询的应答，而且每个查询只答一次：画面在吃字节时由 surface 答，
/// 其余时候由影子答（`TerminalOutputPump`）。真 surface，一边喂类 Claude Code 的输出（每帧开同步输出、夹一个查询、
/// 光标停回输入框、结束同步输出，字节随机切片），一边反复切标签（视图离开 / 回到窗口）、放掉重建 surface、改窗口大小。
///
/// 2026-11-26 排查「Claude Code 输入框里多出 `3;3H`、`?2026l`」时写的。这两条在修之前就是过的：切标签这条路上
/// 没复现出输出序列进输入方向、也没复现出一个查询答两次；那两串字在画面上复现出来了（检查点位置算错，
/// `HeldCheckpointOffsetTests`）。留作这条规矩的回归。
@MainActor
final class GhosttyReplyOwnershipTests: XCTestCase {
    private var rig: GhosttySurfaceRig!

    override func setUp() async throws {
        try await super.setUp()
        rig = await GhosttySurfaceRig()
    }

    override func tearDown() async throws {
        rig?.close()
        rig = nil
        try await super.tearDown()
    }

    private func hide() {
        rig.window.contentView = NSView(frame: rig.container.frame)
    }

    private func show() {
        rig.window.contentView = rig.container
        rig.container.frame = rig.window.contentView?.bounds ?? rig.container.frame
        rig.container.layoutSubtreeIfNeeded()
        rig.window.makeFirstResponder(rig.view)
    }

    private struct Random {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
    }

    /// 输入方向上的一串字节拆成一个个序列；拆不动的（不是 `ESC [ … 终结符`）原样留成一段。
    private func tokens(_ bytes: [UInt8]) -> [String] {
        var result: [String] = []
        var index = 0
        while index < bytes.count {
            var end = index + 1
            if bytes[index] == 0x1B, end < bytes.count, bytes[end] == UInt8(ascii: "[") {
                end += 1
                while end < bytes.count, !(0x40...0x7E).contains(bytes[end]) { end += 1 }
                end = min(end + 1, bytes.count)
            }
            result.append(String(decoding: bytes[index..<end], as: UTF8.self))
            index = end
        }
        return result
    }

    /// 输出量大（3 MB，查询夹在整屏的字中间）时反复切标签：停喂、补尾巴落在大块输出的半中间。不会多答，也不会有别的字节
    /// 进输入方向。没人答的个数只打印：停喂那一刻 surface 队列里排着、还没解析的字节会被拿回来当尾巴，回来时用不应答的入口
    /// 补给 surface，里面的查询影子当时（归 surface 答）也没答——按代码读是没人答的，这台机器上 surface 解析得快，
    /// 队列每次都是空的（`droppedSurfaceBytes` 为 0），没走到。程序等不到应答会超时，不是乱码。
    func testBackloggedOutputAcrossTabSwitchesNeverAnswersTwice() async throws {
        await rig.feed("\u{1B}[?2004h\u{1B}[?1004h\u{1B}[?2031h\u{1B}[2J\u{1B}[H")
        var random = Random(state: 7)
        let queries = 600
        var asked: [String] = []
        var stream: [UInt8] = []
        for index in 0..<queries {
            let row = index / 60 + 2, column = index % 60 + 1
            asked.append("\u{1B}[\(row);\(column)R")
            let filler = String(repeating: "lorem ipsum dolor sit amet ", count: 80 + random.below(200))
            stream += Array(("\u{1B}[?2026h\u{1B}[20;1H" + filler + "\u{1B}[\(row);\(column)H\u{1B}[6n"
                + "\u{1B}[3;3H\u{1B}[?2026l").utf8)
        }
        var hidden = false
        var switches = 0
        var offset = 0
        while offset < stream.count {
            let cut = min(stream.count - offset, 16 * 1024 + random.below(64 * 1024))
            await rig.backend.emitOutput(Data(stream[offset..<(offset + cut)]))
            offset += cut
            if random.below(3) == 0 {
                if hidden { show() } else { hide() }
                hidden.toggle()
                switches += 1
            }
            await Task.yield()
        }
        if hidden { show() }
        rig.keepRendering()
        let total = stream.count
        let fed = await rig.waitUntil(20) { self.rig.session.shadow.totalFedBytes >= total && self.rig.bridge.isLive }
        XCTAssertTrue(fed)
        await rig.feed("")
        try await Task.sleep(for: .milliseconds(300))

        let written = await rig.backend.writtenData.flatMap { [UInt8]($0) }
        var counts: [String: Int] = [:]
        var foreign: [String] = []
        for token in tokens(written) {
            switch token {
            case "\u{1B}[I", "\u{1B}[O", "\u{1B}[0n", "\u{1B}[?997;1n", "\u{1B}[?997;2n": continue
            default:
                if asked.contains(token) { counts[token, default: 0] += 1 } else { foreign.append(token) }
            }
        }
        let printable = { (token: String) in token.replacingOccurrences(of: "\u{1B}", with: "ESC") }
        XCTAssertTrue(foreign.isEmpty, "输入方向上出现了既不是按键也不是应答的字节：\(foreign.prefix(20).map(printable))")
        let twice = asked.filter { (counts[$0] ?? 0) > 1 }
        XCTAssertTrue(twice.isEmpty, "这些查询答了不止一次：\(twice.prefix(10).map(printable))")
        let never = asked.filter { counts[$0] == nil }
        print("[reply-ownership] 积压：查询 \(queries)，\(total) 字节，切标签 \(switches) 次，没人答的 \(never.count) 个，"
              + "泵 \(rig.session.outputPump.currentStats)")
    }

    func testEveryQueryIsAnsweredOnceAndNothingElseReachesTheProgramAcrossTabSwitches() async throws {
        rig.bridge.hiddenReleaseDelay = .milliseconds(60)
        // Claude Code 起来时开的模式里会让终端主动往输入方向写东西的两个：焦点上报、配色变化上报。
        await rig.feed("\u{1B}[?2004h\u{1B}[?1004h\u{1B}[?2031h\u{1B}[2J\u{1B}[H")
        var random = Random(state: 20_261_126)
        let queries = 360
        var asked: [String] = []
        var hidden = false
        var switches = 0, releases = 0

        for index in 0..<queries {
            // 每个查询的光标位置不同，应答（`ESC [ 行 ; 列 R`）就认得出是哪一个。
            let row = index / 60 + 2, column = index % 60 + 1
            asked.append("\u{1B}[\(row);\(column)R")
            let frame = "\u{1B}[?2026h\u{1B}[?25l\u{1B}[\(row);\(column)H\u{1B}[6n\u{1B}[38;2;215;119;87m✻\u{1B}[39m"
                + "\u{1B}[3;3H\u{1B}[?25h\u{1B}[?2026l"
            var bytes = Array(frame.utf8)[...]
            while !bytes.isEmpty {
                let cut = min(bytes.count, 1 + random.below(24))
                await rig.backend.emitOutput(Data(bytes.prefix(cut)))
                bytes = bytes.dropFirst(cut)
                // 切片之间随机切一下标签：停喂、补尾巴、整屏回放都会落在一个序列的半中间。
                switch random.below(40) {
                case 0:
                    if hidden { show() } else { hide() }
                    hidden.toggle()
                    switches += 1
                case 1 where hidden:
                    // 藏久一点：surface 被放掉，回来时重建、整屏回放。
                    try await Task.sleep(for: .milliseconds(150))
                    releases += rig.bridge.isSurfaceReleased ? 1 : 0
                case 2:
                    try await Task.sleep(for: .milliseconds(random.below(12)))
                case 3 where !hidden:
                    var frame = rig.window.frame
                    frame.size.width = 700 + CGFloat(random.below(200))
                    rig.window.setFrame(frame, display: true)
                    rig.container.layoutSubtreeIfNeeded()
                default:
                    break
                }
            }
        }
        if hidden { show() }
        rig.keepRendering()
        let live = await rig.waitUntil(10) { self.rig.bridge.isLive }
        XCTAssertTrue(live)
        // 等影子吃完全部输出，再等 surface 解析到这里（`feed` 末尾的 DSR 5 应答到了才返回）。
        try await Task.sleep(for: .milliseconds(300))
        await rig.feed("")
        try await Task.sleep(for: .milliseconds(300))

        let written = await rig.backend.writtenData.flatMap { [UInt8]($0) }
        var counts: [String: Int] = [:]
        var foreign: [String] = []
        for token in tokens(written) {
            switch token {
            case "\u{1B}[I", "\u{1B}[O", "\u{1B}[0n", "\u{1B}[?997;1n", "\u{1B}[?997;2n":
                continue   // 焦点、配色上报，和夹具用来对齐的那个 DSR 应答。
            default:
                if asked.contains(token) { counts[token, default: 0] += 1 } else { foreign.append(token) }
            }
        }
        let printable = { (token: String) in token.replacingOccurrences(of: "\u{1B}", with: "ESC") }
        XCTAssertTrue(foreign.isEmpty, "输入方向上出现了既不是按键也不是应答的字节：\(foreign.prefix(20).map(printable))")
        let twice = asked.filter { (counts[$0] ?? 0) > 1 }
        let never = asked.filter { counts[$0] == nil }
        XCTAssertTrue(twice.isEmpty, "这些查询答了不止一次：\(twice.prefix(10).map(printable))")
        XCTAssertGreaterThan(switches, 10, "用例前提：切过标签")
        print("[reply-ownership] 查询 \(queries)，切标签 \(switches) 次，放掉 surface \(releases) 次，"
              + "没人答的 \(never.count) 个：\(never.prefix(10).map(printable))，泵 \(rig.session.outputPump.currentStats)")
        XCTAssertTrue(never.isEmpty, "这些查询没人答：\(never.prefix(10).map(printable))（共 \(never.count) 个）")
    }
}
