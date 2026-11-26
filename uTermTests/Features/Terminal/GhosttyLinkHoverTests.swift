import AppKit
import Carbon.HIToolbox
import XCTest
@testable import uTerm

/// 终端里的链接在真 surface 上的往来：按住 ⌘ 指着一个路径 / 网址，引擎认出链接（下划线、手形指针、底部显示地址），
/// ⌘ 点下去交给 `TerminalSession.openTerminalLink`。用户报的「按 ⌘ 没有任何反应」从这里钉住。
@MainActor
final class GhosttyLinkHoverTests: XCTestCase {

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

    private func flags(_ modifiers: NSEvent.ModifierFlags, keyCode: Int = kVK_Command) -> NSEvent {
        NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: modifiers,
                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: rig.window.windowNumber,
                         context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
                         keyCode: UInt16(keyCode))!
    }

    private func move(col: Int, row: Int, modifiers: NSEvent.ModifierFlags = []) {
        guard let point = rig.windowPoint(col: col, row: row) else { return XCTFail("量不到格子尺寸") }
        rig.view.mouseMoved(with: RealEvents.mouse(.mouseMoved, window: rig.window, at: point, modifiers: modifiers))
    }

    /// 先指着路径、再按下 ⌘：不动鼠标也要认出链接（Ghostty 的 macOS App 就是这样），松开 ⌘ 就收回。
    func testPressingCommandOverPathShowsLink() async {
        await rig.feed("Installed /Applications/uTerm.app now\r\n")
        move(col: 14, row: 0)
        rig.view.flagsChanged(with: flags(.command))
        let shown = await rig.waitUntil(2) { self.rig.view.hoveredLink != nil }
        XCTAssertTrue(shown, "按住 ⌘ 指着路径，应当认出链接")
        XCTAssertEqual(rig.view.hoveredLink, "/Applications/uTerm.app")
        XCTAssertEqual(rig.view.mouseCursor, .pointingHand, "指着链接时指针应当是手形")
        XCTAssertTrue(rig.container.linkPreview.isShown, "底部应当显示链接地址")
        XCTAssertEqual(rig.container.linkPreview.text, "/Applications/uTerm.app")

        rig.view.flagsChanged(with: flags([]))
        let hidden = await rig.waitUntil(2) { self.rig.view.hoveredLink == nil }
        XCTAssertTrue(hidden, "松开 ⌘ 链接应当收回")
        XCTAssertEqual(rig.view.mouseCursor, .iBeam, "松开 ⌘ 指针回到文字光标")
        XCTAssertFalse(rig.container.linkPreview.isShown)
    }

    /// 按着 ⌘ 移过去也一样；移开到普通文字上收回。
    func testMovingWithCommandHeldShowsLink() async {
        await rig.feed("see https://example.com/docs here\r\n")
        rig.view.flagsChanged(with: flags(.command))
        move(col: 10, row: 0, modifiers: .command)
        let shown = await rig.waitUntil(2) { self.rig.view.hoveredLink != nil }
        XCTAssertTrue(shown)
        XCTAssertEqual(rig.view.hoveredLink, "https://example.com/docs")

        move(col: 1, row: 0, modifiers: .command)
        let hidden = await rig.waitUntil(2) { self.rig.view.hoveredLink == nil }
        XCTAssertTrue(hidden)
    }

    /// 没按 ⌘ 时不认（普通的点击、拖选不受影响）。
    func testNoLinkWithoutCommand() async {
        await rig.feed("Installed /Applications/uTerm.app now\r\n")
        move(col: 14, row: 0)
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(rig.view.hoveredLink)
        XCTAssertNotEqual(rig.view.mouseCursor, .pointingHand)
    }

    /// ⌘ 点路径：交给 uTerm（SSH 终端在预览区打开）。
    func testCommandClickOpensPath() async {
        await rig.feed("Installed /Applications/uTerm.app now\r\n")
        var requested: [String] = []
        rig.session.onFilePreviewRequest = { requested.append($0) }
        rig.view.flagsChanged(with: flags(.command))
        guard let point = rig.windowPoint(col: 14, row: 0) else { return XCTFail("量不到格子尺寸") }
        rig.view.mouseMoved(with: RealEvents.mouse(.mouseMoved, window: rig.window, at: point, modifiers: .command))
        rig.view.mouseDown(with: RealEvents.mouse(.leftMouseDown, window: rig.window, at: point, modifiers: .command))
        rig.view.mouseUp(with: RealEvents.mouse(.leftMouseUp, window: rig.window, at: point, modifiers: .command))
        let opened = await rig.waitUntil(3) { !requested.isEmpty }
        XCTAssertTrue(opened, "⌘ 点路径应当交给 uTerm 打开")
        XCTAssertEqual(requested.first, "/Applications/uTerm.app")
    }

    // MARK: 本机终端

    private actor LocalOpener: LocalPathOpening {
        nonisolated let outputItems = AsyncStream<TerminalOutputItem> { _ in }
        nonisolated let exitStream = AsyncStream<Void> { _ in }
        private(set) var opened: [String] = []
        func connect() async throws {}
        func write(_ data: Data) async {}
        func resize(cols: UInt16, rows: UInt16) async {}
        func close() async {}
        func foregroundDirectories() async -> RemoteForegroundDirectories? {
            RemoteForegroundDirectories(workingDirectory: "/Users/me/demo", home: "/Users/me")
        }
        func openLocalPath(_ path: String) async -> Bool {
            opened.append(path)
            return true
        }
    }

    private func commandClick(col: Int, row: Int) {
        rig.view.flagsChanged(with: flags(.command))
        guard let point = rig.windowPoint(col: col, row: row) else { return XCTFail("量不到格子尺寸") }
        rig.view.mouseMoved(with: RealEvents.mouse(.mouseMoved, window: rig.window, at: point, modifiers: .command))
        rig.view.mouseDown(with: RealEvents.mouse(.leftMouseDown, window: rig.window, at: point, modifiers: .command))
        rig.view.mouseUp(with: RealEvents.mouse(.leftMouseUp, window: rig.window, at: point, modifiers: .command))
        rig.view.flagsChanged(with: flags([]))
    }

    /// 用户报的：本机终端里 ⌘ 点路径没反应。没有预览区，路径要交给系统打开（`LocalPathOpening`）。
    func testCommandClickInLocalTerminalOpensWithTheSystem() async {
        rig.close()
        rig = await GhosttySurfaceRig(connectsBackend: false)
        let opener = LocalOpener()
        await rig.session.connect(using: opener)
        XCTAssertNil(rig.session.onFilePreviewRequest)
        await rig.feed("1 绝对路径          /Users/me/demo/index.html\r\n2 相对路径          docs/plan.md\r\n")
        commandClick(col: 24, row: 0)
        commandClick(col: 22, row: 1)
        var opened: [String] = []
        _ = await rig.waitUntil(3) {
            opened = await opener.opened
            return opened.count == 2
        }
        XCTAssertEqual(opened, ["/Users/me/demo/index.html", "/Users/me/demo/docs/plan.md"])
    }

    /// Claude Code 这类全屏程序打开了鼠标上报（`?1000h` / `?1002h` / `?1006h`）：⌘ 点路径照样要打开，不能被当成鼠标事件发给程序。
    func testCommandClickOpensPathWhileProgramCapturesTheMouse() async {
        rig.close()
        rig = await GhosttySurfaceRig(connectsBackend: false)
        let opener = LocalOpener()
        await rig.session.connect(using: opener)
        await rig.feed("\u{1b}[?1000h\u{1b}[?1002h\u{1b}[?1006h1 绝对路径          /Users/me/demo/index.html\r\n")
        commandClick(col: 24, row: 0)
        var opened: [String] = []
        _ = await rig.waitUntil(3) {
            opened = await opener.opened
            return !opened.isEmpty
        }
        XCTAssertEqual(opened, ["/Users/me/demo/index.html"])
    }

    /// 鼠标被程序接管时按住 ⌘ 指着路径：一样显示链接；不按 ⌘ 的点击照常发给程序，不当成链接。
    func testCommandHoverShowsLinkWhileProgramCapturesTheMouse() async {
        await rig.feed("\u{1b}[?1000h\u{1b}[?1006hInstalled /Applications/uTerm.app now\r\n")
        move(col: 14, row: 0)
        rig.view.flagsChanged(with: flags(.command))
        let shown = await rig.waitUntil(2) { self.rig.view.hoveredLink != nil }
        XCTAssertTrue(shown, "程序接管鼠标时按住 ⌘ 也要认出链接")
        XCTAssertEqual(rig.view.hoveredLink, "/Applications/uTerm.app")
        rig.view.flagsChanged(with: flags([]))
        let hidden = await rig.waitUntil(2) { self.rig.view.hoveredLink == nil }
        XCTAssertTrue(hidden, "松开 ⌘ 链接收回")

        var opened: [String] = []
        rig.session.onFilePreviewRequest = { opened.append($0) }
        guard let point = rig.windowPoint(col: 14, row: 0) else { return XCTFail("量不到格子尺寸") }
        rig.view.mouseDown(with: RealEvents.mouse(.leftMouseDown, window: rig.window, at: point))
        rig.view.mouseUp(with: RealEvents.mouse(.leftMouseUp, window: rig.window, at: point))
        let reported = await rig.sent(expecting: 1, timeout: 1)
        XCTAssertTrue(String(decoding: reported, as: UTF8.self).contains("\u{1b}[<0;"), "普通点击照常上报给程序")
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(opened.isEmpty, "不按 ⌘ 不打开链接")
    }

    /// 程序接管鼠标时 ⌘ 点一次只打开一次，点击也不报给程序（否则 Claude Code 自己也会再开一次）。
    func testCommandClickWhileCapturedOpensOnceAndReportsNothing() async {
        await rig.feed("\u{1b}[?1000h\u{1b}[?1002h\u{1b}[?1006hInstalled /Applications/uTerm.app now\r\n")
        var opened: [String] = []
        rig.session.onFilePreviewRequest = { opened.append($0) }
        let before = await rig.sent(expecting: 0, timeout: 0.1).count
        guard let point = rig.windowPoint(col: 14, row: 0) else { return XCTFail("量不到格子尺寸") }
        rig.view.flagsChanged(with: flags(.command))
        rig.view.mouseMoved(with: RealEvents.mouse(.mouseMoved, window: rig.window, at: point, modifiers: .command))
        rig.view.mouseDown(with: RealEvents.mouse(.leftMouseDown, window: rig.window, at: point, modifiers: .command))
        rig.view.mouseUp(with: RealEvents.mouse(.leftMouseUp, window: rig.window, at: point, modifiers: .command))
        rig.view.flagsChanged(with: flags([]))
        try? await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(opened, ["/Applications/uTerm.app"], "只打开一次")
        let after = await rig.sent(expecting: before + 1, timeout: 0.3)
        XCTAssertEqual(String(decoding: after.dropFirst(before), as: UTF8.self), "", "⌘ 点不报给程序")
    }
}
