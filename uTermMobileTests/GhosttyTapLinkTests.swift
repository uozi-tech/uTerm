import GhosttyTerminal
import UIKit
import XCTest
@testable import uTermMobile

/// 手机上手指直接点链接就打开：网址、路径都算，程序接管着鼠标（Claude Code）时也一样；开不开同编辑菜单的「打开」
///（远控镜像里的路径不开，点击照常交给终端）。点击经引擎的 ⌘ 点走到 `GhosttyTerminalBridge.onOpenLink`。
@MainActor
final class GhosttyTapLinkTests: XCTestCase {
    private var host: GhosttyProbeHost!
    private var opened: [String] = []

    override func setUp() async throws {
        try await super.setUp()
        host = try GhosttyProbeHost(size: CGSize(width: 393, height: 600), keepsBridgeDelegate: true)
        try await host.waitUntilReady()
        opened = []
        host.bridge.onOpenLink = { [weak self] link, _ in self?.opened.append(link) }
        host.view.onOpenLink = { _ in }
    }

    override func tearDown() async throws {
        host?.close()
        host = nil
        try await super.tearDown()
    }

    /// 第 `row` 行第 `col` 格的中心。
    private func point(col: Int, row: Int) -> CGPoint {
        let cell = CGSize(width: host.view.bounds.width / CGFloat(max(host.grid.cols, 1)),
                          height: host.view.bounds.height / CGFloat(max(host.grid.rows, 1)))
        return CGPoint(x: cell.width * (CGFloat(col) + 0.5), y: cell.height * (CGFloat(row) + 0.5))
    }

    private func show(_ text: String) async throws {
        host.feedAndWait("\u{1B}[H\u{1B}[2J\(text)\r\n")
        try await Task.sleep(for: .milliseconds(150))
    }

    func testTappingAPathOpensIt() async throws {
        try await show("see /tmp/demo/plan.md now")
        XCTAssertTrue(host.view.uTermSendTap(at: point(col: 8, row: 0)), "点到了链接：不弹键盘")
        XCTAssertEqual(opened, ["/tmp/demo/plan.md"])
    }

    func testTappingAWebLinkOpensIt() async throws {
        try await show("docs https://example.com/docs here")
        XCTAssertTrue(host.view.uTermSendTap(at: point(col: 10, row: 0)))
        XCTAssertEqual(opened, ["https://example.com/docs"])
    }

    /// 用户报的：Claude Code 里点不开。程序接管着鼠标时也打开，而且这次点击不报给程序。
    func testTappingALinkOpensItWhileAProgramCapturesTheMouse() async throws {
        try await show("\u{1B}[?1000h\u{1B}[?1006hsee /tmp/demo/plan.md now")
        host.bridge.inputLog = []
        XCTAssertTrue(host.view.uTermSendTap(at: point(col: 8, row: 0)))
        XCTAssertEqual(opened, ["/tmp/demo/plan.md"])
        try await Task.sleep(for: .milliseconds(200))
        let sent = (host.bridge.inputLog ?? []).map { String(decoding: $0, as: UTF8.self) }.joined()
        XCTAssertFalse(sent.contains("\u{1B}[<"), "点链接不当成鼠标事件报给程序：\(sent.debugDescription)")
        host.feedAndWait("\u{1B}[?1006l\u{1B}[?1000l")
    }

    /// 宿主说不开的（远控镜像里的路径）：不打开，点击照常交给终端（弹键盘）。
    func testALinkTheHostWillNotOpenIsAnOrdinaryTap() async throws {
        try await show("see /tmp/demo/plan.md now")
        host.view.canOpenLink = { _ in false }
        XCTAssertFalse(host.view.uTermSendTap(at: point(col: 8, row: 0)))
        XCTAssertTrue(opened.isEmpty)
    }

    func testTappingPlainTextIsAnOrdinaryTap() async throws {
        try await show("hello world")
        XCTAssertFalse(host.view.uTermSendTap(at: point(col: 2, row: 0)))
        XCTAssertTrue(opened.isEmpty)
    }
}
