import AppKit
import SwiftUI
import UPaneGroups
import XCTest
@testable import uTerm

/// shell 用 OSC 0 / 2 设的标题 → 终端标签的显示。
@MainActor
final class TerminalShellTitleTests: XCTestCase {

    private func feed(_ session: TerminalSession, _ text: String) {
        session.feedOutput(text: text)
    }

    func testOSCSequencesSetShellTitle() {
        let session = TerminalSession()
        XCTAssertNil(session.shellTitle)

        feed(session, "\u{1b}]0;vim main.swift\u{07}")
        XCTAssertEqual(session.shellTitle, "vim main.swift")

        feed(session, "\u{1b}]2;alice@web-1: ~/app\u{07}")
        XCTAssertEqual(session.shellTitle, "alice@web-1: ~/app")
    }

    /// 程序退出前常把标题清空：要回到服务器名，不能留一个空标签。
    func testBlankTitleClearsShellTitle() {
        let session = TerminalSession()
        feed(session, "\u{1b}]0;vim\u{07}")
        feed(session, "\u{1b}]0;   \u{07}")
        XCTAssertNil(session.shellTitle)
    }

    /// 连接没了，标题说的那个程序也不在了。
    func testLeavingConnectedClearsShellTitle() {
        let session = TerminalSession()
        feed(session, "\u{1b}]0;vim\u{07}")
        session.markFailed("断了")
        XCTAssertNil(session.shellTitle)
    }

    func testTabShowsServerNameUntilShellSetsTitle() {
        let pane = PaneModel(serverProfileID: UUID(), tabTitle: "web-1")
        let tab = TerminalTab(payload: pane)

        XCTAssertEqual(TerminalArea.descriptor(for: tab, profiles: [:]).title, "web-1")

        feed(pane.session, "\u{1b}]0;vim\u{07}")
        let descriptor = TerminalArea.descriptor(for: tab, profiles: [:])
        XCTAssertEqual(descriptor.title, "vim")
        XCTAssertEqual(descriptor.help?.hasPrefix("vim\nweb-1"), true)
        // 组件里 customTitle 优先于 descriptor：这里有值，shell 标题就显示不出来。
        XCTAssertNil(tab.customTitle)
    }

    /// 标签宽度随标题撑开，长标题要截短；全文留在悬停提示里。
    func testLongShellTitleIsClippedInTabButNotInHelp() {
        let pane = PaneModel(serverProfileID: UUID(), tabTitle: "web-1")
        let tab = TerminalTab(payload: pane)
        let long = "alice@web-1: /var/www/releases/2026/current/public/assets"

        feed(pane.session, "\u{1b}]0;\(long)\u{07}")
        let descriptor = TerminalArea.descriptor(for: tab, profiles: [:])

        XCTAssertEqual(descriptor.title.count, 28)
        XCTAssertTrue(descriptor.title.hasSuffix("…"))
        XCTAssertEqual(descriptor.help?.hasPrefix(long), true)
    }

    /// 所有打开标签的入口都不能再写 `customTitle`，否则它会盖掉 shell 标题。
    func testOpenSplitAndRestoreLeaveCustomTitleEmpty() {
        let workspace = WorkspaceModel()
        workspace.openServer(profileID: UUID(), title: "web-1")
        workspace.splitActiveGroup(direction: .horizontal)

        XCTAssertEqual(workspace.terminalGroups.allTabs.count, 2)
        for tab in workspace.terminalGroups.allTabs {
            XCTAssertNil(tab.customTitle)
            XCTAssertEqual(tab.payload.tabTitle, "web-1")
        }

        let restored = WorkspaceModel(snapshot: workspace.snapshot())
        XCTAssertEqual(restored.terminalGroups.allTabs.count, 2)
        for tab in restored.terminalGroups.allTabs {
            XCTAssertNil(tab.customTitle)
            XCTAssertEqual(tab.payload.tabTitle, "web-1")
        }
    }

    /// 真挂上标签条：OSC 到了之后那一枚标签要跟着变，而且只有它变（程序可能每秒改很多次标题，
    /// 不能牵动面板内容）。
    func testMountedChipFollowsShellTitleWithoutRebuildingPanes() async throws {
        let workspace = WorkspaceModel()
        workspace.openServer(profileID: UUID(), title: "web-1")
        let session = try XCTUnwrap(workspace.terminalGroups.activeTab).payload.session

        var titles: [String] = []
        var contentBuilds = 0
        let area = UPaneGroupArea(
            model: workspace.terminalGroups,
            dragType: .utermTabID,
            descriptor: { tab in
                let descriptor = TerminalArea.descriptor(for: tab, profiles: [:])
                titles.append(descriptor.title)
                return descriptor
            },
            content: { _, _ in
                contentBuilds += 1
                return SwiftUI.Color.clear
            },
            emptyGroup: { _ in SwiftUI.Color.clear },
            onRequestClose: { _ in })
        let size = NSSize(width: 600, height: 300)
        let host = NSHostingView(rootView: area)
        let window = ProbeWindow.make(contentRect: NSRect(origin: .zero, size: size),
                                      styleMask: [.borderless],
                                      contentView: host)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(titles.last, "web-1")

        let buildsBefore = contentBuilds
        feed(session, "\u{1b}]0;vim main.swift\u{07}")
        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(titles.last, "vim main.swift")
        XCTAssertEqual(contentBuilds, buildsBefore, "标题变化不该重建面板内容")
    }
}
