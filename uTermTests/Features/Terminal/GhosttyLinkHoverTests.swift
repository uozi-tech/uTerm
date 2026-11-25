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
}
