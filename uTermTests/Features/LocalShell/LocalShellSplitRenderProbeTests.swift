import AppKit
import SwiftTerm
import SwiftUI
import UPaneGroups
import XCTest
@testable import uTerm

/// 本机终端分屏的真实渲染：真窗口 + 真 shell（走内嵌 XPC 服务）。
///
/// 拖动手势本身是组件的（SSH 终端窗口同一套），这里验拖完之后的结果：两个 shell 都还活着，
/// 终端视图挂在各自那一格里、宽度确实分开了。截图写到宿主的 tmp，路径打在日志里，便于肉眼看。
@MainActor
final class LocalShellSplitRenderProbeTests: XCTestCase {

    func test_dragging_a_tab_to_the_edge_shows_both_shells_side_by_side() async throws {
        let model = LocalShellWindowModel()
        let window = ProbeWindow.make(contentRect: NSRect(x: 0, y: 0, width: 960, height: 560))
        let host = NSHostingView(rootView: LocalShellTerminalArea(model: model))
        host.frame = NSRect(origin: .zero, size: NSSize(width: 960, height: 560))
        window.contentView = host
        defer {
            model.disposeAll()
            window.contentView = NSView()
            window.orderOut(nil)
        }

        let first = model.addTab()
        let second = model.addTab()
        let panes = try [first, second].map { try XCTUnwrap(model.groups.tab($0)?.payload) }
        await waitUntil("两个 shell 都起来") {
            panes.allSatisfy { $0.session.connectionState == .connected }
        }

        let group = try XCTUnwrap(model.groups.activeGroupID)
        model.groups.moveTab(second, toGroup: group, zone: .trailing)
        XCTAssertEqual(model.groups.groupCount, 2)

        func frame(_ pane: LocalShellPane) -> NSRect {
            let view = pane.session.terminalView
            guard view.window === window else { return .zero }
            return view.convert(view.bounds, to: nil)
        }
        await waitUntil("两个终端各占一格") {
            frame(panes[0]).width > 300 && frame(panes[1]).width > 300
                && frame(panes[0]).maxX <= frame(panes[1]).minX
        }
        for pane in panes {
            XCTAssertEqual(pane.session.connectionState, .connected, "拖动不能断掉 shell")
        }

        try? await Task.sleep(for: .milliseconds(500))
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        // 宿主在沙盒里，只写得了自己的 tmp。
        let png = FileManager.default.temporaryDirectory.appendingPathComponent("local-shell-split.png")
        try rep.representation(using: .png, properties: [:])?.write(to: png)
        print("[LocalShellSplit] 截图：\(png.path)")

        // 两个 shell 都能收发，而且收发不串。
        for (index, pane) in panes.enumerated() {
            pane.session.writeRemoteInput(Data("echo PANE_$((\(index)+7))\n".utf8))
        }
        await waitUntil("各自回显") {
            let texts = panes.map { String(decoding: $0.session.terminalView.getTerminal().getBufferAsData(), as: UTF8.self) }
            return texts[0].contains("PANE_7") && texts[1].contains("PANE_8")
        }
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 20,
                           _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("等不到：\(what)") }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}
