import XCTest
@testable import uTerm

final class WorkspaceChromeTitleTests: XCTestCase {
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
            "SFTP — demo-server · prod"
        )
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
