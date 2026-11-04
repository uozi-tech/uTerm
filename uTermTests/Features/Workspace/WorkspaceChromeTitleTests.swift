import AppKit
import SwiftUI
import XCTest
@testable import uTerm

final class WorkspaceChromeTitleTests: XCTestCase {
    func testWindowMoveDoesNotAdjustFrameForScreenLayout() {
        WindowMoveBehavior.disableScreenLayoutAdjustment()

        let value = UserDefaults.standard.object(forKey: "NSScreenLayoutAdjustOnWindowMove") as? Bool
        XCTAssertEqual(value, false)
    }

    func testServerChromeTitleAppendsGroupName() {
        XCTAssertEqual(
            ServerChromeTitle.serverTitle(serverName: "demo-server", groupName: "prod"),
            "demo-server · prod"
        )
    }

    func testServerChromeTitleOmitsBlankGroupName() {
        XCTAssertEqual(
            ServerChromeTitle.serverTitle(serverName: "demo-server", groupName: nil),
            "demo-server"
        )
        XCTAssertEqual(
            ServerChromeTitle.serverTitle(serverName: "demo-server", groupName: "   "),
            "demo-server"
        )
    }

    func testSFTPChromeTitleIncludesServerAndGroupName() {
        XCTAssertEqual(
            ServerChromeTitle.sftpWindowTitle(serverName: "demo-server", groupName: "prod"),
            "demo-server · prod — SFTP"
        )
    }

    func testWindowTitlesPutContentBeforeWindowKind() {
        XCTAssertEqual(
            ServerChromeTitle.terminalWindowTitle(serverName: "demo-server", groupName: "prod"),
            "demo-server · prod — 终端"
        )
        XCTAssertEqual(
            ServerChromeTitle.portForwardWindowTitle(serverName: "demo-server", groupName: nil),
            "demo-server — 端口转发"
        )
        XCTAssertEqual(
            ServerChromeTitle.parallelRunWindowTitle(commandName: "重启 nginx"),
            "重启 nginx — 并行执行"
        )
        XCTAssertEqual(
            ServerChromeTitle.localShellWindowTitle(tabTitle: "zsh 2"),
            "zsh 2 — 本机终端"
        )
    }

    func testWindowTitlesFallBackToWindowKindWithoutContent() {
        XCTAssertEqual(ServerChromeTitle.parallelRunWindowTitle(commandName: nil), "并行执行")
        XCTAssertEqual(ServerChromeTitle.localShellWindowTitle(tabTitle: nil), "本机终端")
    }

    @MainActor
    func testLocalShellWindowTitleFollowsActiveTab() throws {
        let model = LocalShellWindowModel(startShell: { _ in })
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: LocalShellWindowTitleBinding(model: model))

        waitForTitle("本机终端", in: window)

        let firstID = model.addTab()
        let firstPane = try XCTUnwrap(model.active)
        let shellName = firstPane.defaultTitle
        waitForTitle("\(shellName) — 本机终端", in: window)

        firstPane.session.receiveShellTitle("~/Workspace/uTerm")
        waitForTitle("~/Workspace/uTerm — 本机终端", in: window)

        model.addTab()
        waitForTitle("\(shellName) 2 — 本机终端", in: window)

        XCTAssertTrue(model.close(try XCTUnwrap(model.active?.id)))
        XCTAssertEqual(model.active?.id, firstID)
        waitForTitle("~/Workspace/uTerm — 本机终端", in: window)
        model.disposeAll()
    }

    @MainActor
    private func waitForTitle(
        _ expected: String,
        in window: NSWindow,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(2)
        while window.title != expected, Date() < deadline {
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(window.title, expected, file: file, line: line)
    }

    func testWorkspaceAndSFTPViewsPassGroupNameToChromeTitles() throws {
        let workspaceSource = try normalizedSource("uTerm/Features/Workspace/Views/WorkspaceWindowView.swift")
        let sftpSource = try normalizedSource("uTerm/Features/SFTP/Views/SFTPWindowView.swift")

        XCTAssertTrue(workspaceSource.contains("serverChromeTitle(for: server)"))
        XCTAssertTrue(sftpSource.contains("ServerChromeTitle.serverTitle(serverName: server.name, groupName: server.group)"))
        XCTAssertTrue(sftpSource.contains("ServerChromeTitle.sftpWindowTitle("))
        XCTAssertTrue(sftpSource.contains("serverName: server.name"))
        XCTAssertTrue(sftpSource.contains("groupName: server.group"))
    }

    func testAgentTitleBarButtonReflectsInspectorVisibility() throws {
        let chromeSource = try normalizedSource("uTerm/Features/Workspace/Views/WorkspaceChrome.swift")
        let workspaceSource = try normalizedSource("uTerm/Features/Workspace/Views/WorkspaceWindowView.swift")

        XCTAssertTrue(workspaceSource.contains(
            "inspectorPresented: workspace.uiState.rightInspectorPresented"
        ))
        XCTAssertTrue(chromeSource.contains(
            "systemName: inspectorPresented ? \"bubble.left.fill\" : \"bubble.left\""
        ))
        XCTAssertTrue(chromeSource.contains("selected: inspectorPresented"))
        XCTAssertTrue(chromeSource.contains(
            "selected ? UD.accentTint : (hover ? UD.rowHover : .clear)"
        ))
        XCTAssertTrue(chromeSource.contains(
            "selected ? [.isButton, .isSelected] : .isButton"
        ))
    }

    private func normalizedSource(_ path: String) throws -> String {
        try source(path).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
