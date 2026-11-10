import AppKit
import Carbon.HIToolbox
import GhosttyTerminal
import XCTest
@testable import uTerm

/// 原来核的是旧引擎的本地补丁 #14：换字号不能重置终端状态（上游换字号时走 `softReset()`，光标隐藏、方向键
/// 模式、当前颜色都被清掉，vim 里的方向键就此发错序列）。
///
/// 现在换字体 / 字号 / 光标 / 历史这类设置都是「整份 Ghostty 配置重载」（`GhosttyTerminalBridge.apply(settings:)` →
/// `TerminalController.setTerminalConfiguration`，所有窗格一起生效），同一条要求变成：配置重载不能重置程序设的模式，
/// 字号变了、行列数跟着变时程序照样收到新尺寸。程序不知道设置变了，也不会把模式重新设一遍。
@MainActor
final class TerminalFontChangeTests: XCTestCase {
    /// vim、Claude Code 这类全屏程序会设的状态。
    private static let programState = [
        "\u{1b}[?1049h",   // 备用屏
        "\u{1b}[?1h",      // 方向键发应用模式序列
        "\u{1b}[?25l",     // 隐藏光标
        "\u{1b}[?7l",      // 关自动折行
        "\u{1b}[?2004h",   // 括号粘贴
        "\u{1b}[?6h",      // 原点模式
        "\u{1b}[5;10r",    // 滚动区域
        "\u{1b}[31m",      // 当前颜色
    ].joined()

    private var rigs: [GhosttySurfaceRig] = []

    override func tearDown() async throws {
        rigs.forEach { $0.close() }
        rigs = []
        // 把进程里共用的那份 Ghostty 配置还原成当前设置。
        GhosttyTerminalConfig.controller.setTerminalConfiguration(GhosttyTerminalConfig.base(settings: .read()))
        try await super.tearDown()
    }

    private func makeRig() async -> GhosttySurfaceRig {
        let rig = await GhosttySurfaceRig()
        rigs.append(rig)
        return rig
    }

    /// 当前设置的那份配置，只把字号换掉。
    private func configuration(fontSize: Float) -> GhosttyTerminal.TerminalConfiguration {
        GhosttyTerminal.TerminalConfiguration(startingFrom: GhosttyTerminalConfig.base(settings: .read())) { b in
            b.withFontSize(fontSize)
        }
    }

    private func upArrow(_ rig: GhosttySurfaceRig) async -> String {
        let bytes = await rig.press(characters: "\u{F700}", keyCode: kVK_UpArrow, modifiers: [.function, .numericPad])
        return String(decoding: bytes, as: UTF8.self)
    }

    /// 字号变了、行列数也变了：模式不能动——方向键还是发应用模式的序列。影子终端（解析的那一半）同样只是改了尺寸。
    func testFontChangeThatResizesKeepsModes() async throws {
        let rig = await makeRig()
        await rig.feed(Self.programState)
        let before = try XCTUnwrap(rig.bridge.grid)
        let app = await upArrow(rig)
        XCTAssertEqual(app, "\u{1b}OA", "用例前提：程序开了应用方向键模式")

        GhosttyTerminalConfig.controller.setTerminalConfiguration(configuration(fontSize: 18))
        let resized = await rig.waitUntil(5) { (rig.bridge.grid?.cols ?? before.cols) < before.cols }
        XCTAssertTrue(resized, "前提：这次换字号要改变行列数（\(before) → \(String(describing: rig.bridge.grid))）")

        let after = await upArrow(rig)
        XCTAssertEqual(after, "\u{1b}OA", "换字号之后方向键模式不能被重置")
        let shadow = rig.session.shadow
        XCTAssertTrue(shadow.isOnAlternateScreen)
        XCTAssertTrue(shadow.isModeSet(1), "应用方向键")
        XCTAssertFalse(shadow.cursor.visible, "光标还是藏着的")
        XCTAssertFalse(shadow.isModeSet(7), "自动折行还是关着的")
        XCTAssertTrue(shadow.bracketedPasteMode)
        XCTAssertTrue(shadow.isModeSet(6), "原点模式")
    }

    /// 行列数没变时（重载的是别的设置：光标形状），什么都不该变：方向键模式还在，影子终端一个字节都没动。
    func testConfigReloadThatKeepsGridChangesNothing() async throws {
        let rig = await makeRig()
        await rig.feed(Self.programState)
        let grid = try XCTUnwrap(rig.bridge.grid)
        let snapshot = try rig.session.shadow.snapshot()
        let resizesBefore = await rig.backend.resizes.count

        var settings = TerminalSettings.read()
        settings.cursorShape = settings.cursorShape == .bar ? .underline : .bar
        settings.cursorBlink.toggle()
        GhosttyTerminalConfig.controller.setTerminalConfiguration(GhosttyTerminalConfig.base(settings: settings))
        try await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(rig.bridge.grid?.cols, grid.cols)
        XCTAssertEqual(rig.bridge.grid?.rows, grid.rows)
        let arrow = await upArrow(rig)
        XCTAssertEqual(arrow, "\u{1b}OA", "重载配置之后方向键模式不能被重置")
        XCTAssertEqual(try rig.session.shadow.snapshot(), snapshot, "影子终端不受配置重载影响")
        let resizesAfter = await rig.backend.resizes.count
        XCTAssertEqual(resizesAfter, resizesBefore, "网格没变：不给程序发 SIGWINCH")
    }

    /// uTerm 没有行距设置（`TerminalSettings.lineHeight` 是常数）；Ghostty 上行距也是配置项（adjust-cell-height），
    /// 改它和改字号走同一条「整份配置重载」，由上面两条覆盖。
    func testLineSpacingChangeKeepsModesAndPen() throws {
        throw XCTSkip("uTerm 没有行距设置；Ghostty 上改行距与改字号同走配置重载，见 testFontChangeThatResizesKeepsModes")
    }

    /// 尺寸通知不能跟着丢：字号变了、行列数变了，程序靠它收到 SIGWINCH；影子终端跟到同一个网格。
    func testFontChangeStillReportsNewSize() async throws {
        let rig = await makeRig()
        let before = try XCTUnwrap(rig.bridge.grid)
        let told = await rig.waitUntil(2) {
            let last = await rig.backend.resizes.last
            return last.map { Int($0.cols) == before.cols && Int($0.rows) == before.rows } ?? false
        }
        XCTAssertTrue(told, "用例前提：PTY 已经收到当前网格")

        GhosttyTerminalConfig.controller.setTerminalConfiguration(configuration(fontSize: 18))
        let resized = await rig.waitUntil(5) { (rig.bridge.grid?.cols ?? before.cols) < before.cols }
        XCTAssertTrue(resized)
        // 等网格停住再比。
        try await Task.sleep(for: .milliseconds(300))
        let grid = try XCTUnwrap(rig.bridge.grid)
        let reported = await rig.waitUntil(2) {
            let last = await rig.backend.resizes.last
            return last.map { Int($0.cols) == grid.cols && Int($0.rows) == grid.rows } ?? false
        }
        let sizes = await rig.backend.resizes.suffix(3).map { "\($0.cols)×\($0.rows)" }
        XCTAssertTrue(reported, "PTY 应当收到 \(grid.cols)×\(grid.rows)：最近几次是 \(sizes)")
        XCTAssertEqual(rig.session.shadow.size.cols, grid.cols)
        XCTAssertEqual(rig.session.shadow.size.rows, grid.rows)
    }
}
