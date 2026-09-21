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
    ///
    /// 2026-09-08 再改一次：鼠标的单 / 双击从行里搬到了 `ServerList` 的容器级
    /// `clickToSelect`（行里两个 `onTapGesture` 链式会让 SwiftUI 等满系统双击间隔
    /// 才发单击，实测点一行 390~510ms 才高亮）。所以这里钉的是「行里没有点击手势 +
    /// 容器层接线在 + AX 默认动作在」，真按下去零延迟由 `ClickSelectActivateTests`
    /// 用真 `NSEvent` 验。
    func testServerRowKeepsSingleTapSelectionWithHandWrittenAccessibility() throws {
        let source = try String(contentsOf: repoRoot.appendingPathComponent(
            "uTerm/Features/Welcome/Views/ServerRow.swift"
        ), encoding: .utf8)
        let listSource = try String(contentsOf: repoRoot.appendingPathComponent(
            "uTerm/Features/Welcome/Views/ServerList.swift"
        ), encoding: .utf8)

        XCTAssertFalse(source.contains(".onTapGesture"),
                       "行里不能挂点击手势 —— 单 / 双击互斥消歧会让单击延迟半秒")
        XCTAssertTrue(listSource.contains(".clickToSelect("), "单 / 双击走容器级点击层")
        XCTAssertTrue(source.contains(".accessibilityAction { onTap() }"))
        XCTAssertTrue(source.contains("accessibilityAction(named: Text(\"打开\"))"),
                      "双击的 AX 等价路径必须还在")
        XCTAssertFalse(source.contains("Button(action: onTap)"))
    }

    func testServerRowUsesGroupColorForDotAndBadge() throws {
        let source = try String(contentsOf: repoRoot.appendingPathComponent(
            "uTerm/Features/Welcome/Views/ServerRow.swift"
        ), encoding: .utf8)

        // 状态点在 a72371e4 从 UDHostDot（SwiftUI repeatForever）换成了 CA 驱动的 PulseDot，
        // 这里钉的是「点的颜色取分组色、没有分组才退回强调色」，与点用哪个实现无关。
        XCTAssertTrue(source.contains("PulseDot(color: groupColor ?? UD.accent"),
                      "服务器行的状态点必须取分组色，没有分组才退回强调色")
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
