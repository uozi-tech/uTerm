import XCTest
import UDesignKit
@testable import uTerm

final class WelcomeEqualPaddingLayoutTests: XCTestCase {
    func testServerListRowsDoNotAddOuterGutterOrGap() {
        XCTAssertEqual(ServerListLayout.contentPadding, 0)
        XCTAssertEqual(ServerListLayout.rowSpacing, 0)
    }

    func testServerRowDoesNotDeclareFocusBorderBehavior() throws {
        let source = try String(contentsOf: repoRoot.appendingPathComponent(
            "uTerm/Features/Welcome/Views/ServerRow.swift"
        ), encoding: .utf8)

        XCTAssertFalse(source.contains("@FocusState"))
        XCTAssertFalse(source.contains(".focusable("))
        XCTAssertFalse(source.contains(".focusEffectDisabled("))
        XCTAssertFalse(source.contains("focusRing"))
    }

    func testServerRowUsesButtonSelectionInsteadOfSingleTapGesture() throws {
        let source = try String(contentsOf: repoRoot.appendingPathComponent(
            "uTerm/Features/Welcome/Views/ServerRow.swift"
        ), encoding: .utf8)

        XCTAssertTrue(source.contains("Button(action: onTap)"))
        XCTAssertTrue(source.contains(".buttonStyle(.plain)"))
        XCTAssertFalse(source.contains(".onTapGesture { onTap() }"))
    }

    func testServerRowUsesGroupColorForDotAndBadge() throws {
        let source = try String(contentsOf: repoRoot.appendingPathComponent(
            "uTerm/Features/Welcome/Views/ServerRow.swift"
        ), encoding: .utf8)

        XCTAssertTrue(source.contains("UDHostDot(color: groupColor ?? UD.accent"))
        XCTAssertTrue(source.contains("UDGroupChip(groupLabel, tint: groupColor)"))
        XCTAssertFalse(source.contains("UDGroupChip(groupLabel)"))
    }

    func testWelcomeListPassesServerGroupColorsToRows() throws {
        let welcomeSource = try String(contentsOf: repoRoot.appendingPathComponent(
            "uTerm/Features/Welcome/Views/WelcomeView.swift"
        ), encoding: .utf8)
        let listSource = try String(contentsOf: repoRoot.appendingPathComponent(
            "uTerm/Features/Welcome/Views/ServerList.swift"
        ), encoding: .utf8)

        XCTAssertTrue(welcomeSource.contains("@Query private var groups: [ServerGroup]"))
        XCTAssertTrue(welcomeSource.contains("groupColorHexes: groupColorHexes"))
        XCTAssertTrue(listSource.contains("let groupColorHexes: [String: String]"))
        XCTAssertTrue(listSource.contains("groupColor: ServerGroupBadgeTint.color(for: profile.group"))
    }

    func testWelcomeContextMenuOmitsCopySSHConnectionAction() throws {
        let welcomeSource = try String(contentsOf: repoRoot.appendingPathComponent(
            "uTerm/Features/Welcome/Views/WelcomeView.swift"
        ), encoding: .utf8)
        let listSource = try String(contentsOf: repoRoot.appendingPathComponent(
            "uTerm/Features/Welcome/Views/ServerList.swift"
        ), encoding: .utf8)

        XCTAssertFalse(listSource.contains("复制 SSH 连接"))
        XCTAssertFalse(listSource.contains("copySSH"))
        XCTAssertFalse(welcomeSource.contains(".copySSH"))
    }

    func testServerRowUsesEqualEdgePadding() {
        XCTAssertEqual(ServerRowLayout.contentPadding, UD.Space.xl)
    }

    func testServerFormInfoCardUsesEqualEdgePadding() {
        XCTAssertEqual(ServerFormLayout.infoCardPadding, UD.Space.lg)
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
