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

        // 行首从分组色圆点换成了与 iOS 同构的头像（分组色色块 + 首字母，角标 = 在线状态）。
        // 这里钉的是「色块取分组色」与「角标读在线探测」，不钉头像内部怎么画。
        XCTAssertTrue(source.contains("HostAvatar(monogram: profile.monogram,\n                       tint: groupColor,"),
                      "服务器行的头像色块必须取分组色")
        XCTAssertTrue(source.contains("reachability: HostReachabilityMonitor.shared.entry(for: profile)"),
                      "头像角标必须是服务器在线状态")
        XCTAssertTrue(source.contains("await HostReachabilityMonitor.shared.watch(key)"),
                      "行可见期间要登记在线探测")
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
        XCTAssertTrue(welcomeSource.contains("groupColors: ServerGroupTint.colors(for: groups)"))
        XCTAssertTrue(listSource.contains("let groupColors: [String: Color]"))
        XCTAssertTrue(listSource.contains("groupColor: ServerGroupTint.color(for: profile.group, colors: groupColors)"))
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
