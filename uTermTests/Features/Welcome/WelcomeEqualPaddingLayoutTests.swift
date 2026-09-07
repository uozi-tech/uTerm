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

    /// 原名 `testServerRowUsesButtonSelectionInsteadOfSingleTapGesture`。
    ///
    /// 那一版把「单击选中」钉在 `Button(action: onTap)` 这个**实现**上。
    /// 2026-09-07 的渲染成本评估把行改成了 `onTapGesture + 手工 AX`
    /// （每行一个 plain `Button` 会常驻一个 `_FocusRingView` + 一个
    /// `KeyViewProxy`：2000 台档实测 NSView 91 → 29、单帧 p50 4.47 → 2.32ms，
    /// 见 `WelcomeServerListCostTests` 与 `docs/scroll-perf-findings.md`）。
    ///
    /// 于是这条重新钉在**契约**上而不是实现上：单击必须选中、双击必须打开、
    /// 而且换掉 `Button` 之后必须手工把 AX 默认动作补回来（这一条比原来更严）。
    /// 真按下去有没有反应由 `WelcomeServerListContractTests` 走 AX 树验。
    func testServerRowKeepsSingleTapSelectionWithHandWrittenAccessibility() throws {
        let source = try String(contentsOf: repoRoot.appendingPathComponent(
            "uTerm/Features/Welcome/Views/ServerRow.swift"
        ), encoding: .utf8)

        XCTAssertTrue(source.contains(".onTapGesture { onTap() }"))
        XCTAssertTrue(source.contains(".onTapGesture(count: 2) { onDoubleTap() }"))
        XCTAssertTrue(source.contains(".accessibilityAction { onTap() }"))
        XCTAssertFalse(source.contains("Button(action: onTap)"))
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
