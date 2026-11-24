import GhosttyTerminal
import UIKit
import XCTest
@testable import uTermMobile

/// 选中网址时编辑菜单里的「打开」只有一项。
///
/// libghostty-spm 2.2.2026112401 起，引擎认出手指下是链接时，上游的菜单自己带一项「Open Link」（`terminal.openLink`）。
/// uTerm 选中网址 / 路径时有自己带名字的一项（`uterm.openLink`，判断规则两端共用），放了自己的就不再留上游那项。
@MainActor
final class GhosttyOpenLinkMenuTests: XCTestCase {
    private func identifiers(_ items: [UIMenuElement]) -> [String] {
        items.compactMap { ($0 as? UIAction)?.identifier.rawValue }
    }

    func testSelectedWebLinkShowsOneOpenItem() async throws {
        let host = try GhosttyProbeHost(size: CGSize(width: 393, height: 600))
        try await host.waitUntilReady()
        defer { host.close() }
        let link = "https://example.com/docs"
        host.feedAndWait("\u{1B}[H\u{1B}[2J\(link)\r\n")
        try await Task.sleep(for: .milliseconds(150))
        host.view.onOpenLink = { _ in }

        // 第一行、网址中间的一格。
        let cell = CGSize(width: host.view.bounds.width / CGFloat(max(host.grid.cols, 1)),
                          height: host.view.bounds.height / CGFloat(max(host.grid.rows, 1)))
        let point = CGPoint(x: cell.width * 8, y: cell.height / 2)

        let plain = identifiers(host.view.touchMenuItems(for: TerminalTouchMenuContext(sourcePoint: point)))
        XCTAssertTrue(plain.contains("terminal.openLink"), "自证：引擎认出这一格是链接，没选中时上游那一项在：\(plain)")

        let selected = identifiers(host.view.touchSelectionMenuItems(
            for: TerminalTouchSelectionMenuContext(sourcePoint: point, selectedText: link)))
        XCTAssertEqual(selected.first, "uterm.openLink", "\(selected)")
        XCTAssertFalse(selected.contains("terminal.openLink"), "放了自己的「打开」就不留上游那项：\(selected)")
        XCTAssertTrue(selected.contains("terminal.copy"), "别的项照旧：\(selected)")
    }

    /// 选中的是一条我们不开的链接（远控镜像里的路径、不认的 scheme）：两项都不放，上游那项点了也不会发生什么。
    func testNoOpenItemForALinkWeDoNotOpen() async throws {
        let host = try GhosttyProbeHost(size: CGSize(width: 393, height: 600))
        try await host.waitUntilReady()
        defer { host.close() }
        let link = "https://example.com/docs"
        host.feedAndWait("\u{1B}[H\u{1B}[2J\(link)\r\n")
        try await Task.sleep(for: .milliseconds(150))
        host.view.onOpenLink = { _ in }
        host.view.canOpenLink = { _ in false }

        let cell = CGSize(width: host.view.bounds.width / CGFloat(max(host.grid.cols, 1)),
                          height: host.view.bounds.height / CGFloat(max(host.grid.rows, 1)))
        let point = CGPoint(x: cell.width * 8, y: cell.height / 2)
        let selected = identifiers(host.view.touchSelectionMenuItems(
            for: TerminalTouchSelectionMenuContext(sourcePoint: point, selectedText: link)))
        XCTAssertFalse(selected.contains("uterm.openLink"), "\(selected)")
        XCTAssertFalse(selected.contains("terminal.openLink"), "\(selected)")
        XCTAssertTrue(selected.contains("terminal.copy"), "别的项照旧：\(selected)")
    }

    /// 选中的文字里我们认不出链接（只选中了网址的一段）：上游那项留着，它按引擎认出的整条链接打开。
    func testUpstreamOpenItemStaysWhenTheSelectionIsNotALink() async throws {
        let host = try GhosttyProbeHost(size: CGSize(width: 393, height: 600))
        try await host.waitUntilReady()
        defer { host.close() }
        host.feedAndWait("\u{1B}[H\u{1B}[2Jhttps://example.com/docs\r\n")
        try await Task.sleep(for: .milliseconds(150))
        host.view.onOpenLink = { _ in }

        let cell = CGSize(width: host.view.bounds.width / CGFloat(max(host.grid.cols, 1)),
                          height: host.view.bounds.height / CGFloat(max(host.grid.rows, 1)))
        let point = CGPoint(x: cell.width * 8, y: cell.height / 2)
        let selected = identifiers(host.view.touchSelectionMenuItems(
            for: TerminalTouchSelectionMenuContext(sourcePoint: point, selectedText: "example")))
        XCTAssertFalse(selected.contains("uterm.openLink"), "\(selected)")
        XCTAssertTrue(selected.contains("terminal.openLink"), "\(selected)")
    }
}
