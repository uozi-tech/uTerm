import AppKit
import SwiftUI
import UDesignKit
import XCTest
@testable import uTerm

/// 欢迎页服务器列表的**行为闸门**：`ServerRow` 从 `Button` 换成
/// `onTapGesture + 手工 AX` 之后，选中 / 双击打开 / 无障碍 / 右键 / 拖拽 /
/// 键盘导航六条契约一条都不能少。
///
/// **为什么走 AX 而不是合成 `NSEvent`**：SwiftUI 的手势只认真实光标 ——
/// `window.sendEvent` / `NSHostingView.mouseDown` / 命中视图 `mouseDown`
/// 三条路都驱动不了 `onTapGesture`，而且**改前那版 `Button` 同样点不动**
/// （uTable playbook §五·八·④ 已用对照臂证明这是夹具边界，不是改动回归）。
/// `accessibilityPerformPress` 是 VoiceOver 与「全键盘控制」按下一行走的
/// 真实路径，不是后门。
///
/// **鼠标那条路 2026-09-08 起量得到了**：单 / 双击已搬到 `ServerList` 的容器级
/// AppKit 点击层，合成 `NSEvent` 走 `NSApp.sendEvent` 就能驱动它 ——
/// 见 `ClickSelectActivateTests`。这里保留的是 AX 那条路的契约。
@MainActor
final class WelcomeServerListContractTests: XCTestCase {

    private var windows: [NSWindow] = []

    private func closeAllWindows() {
        for window in windows {
            window.contentView = NSView()
            window.orderOut(nil)
        }
        windows.removeAll()
    }

    // MARK: - 夹具

    private final class Recorder {
        var tapped: [String] = []
        var opened: [String] = []
    }

    private struct RowHarness: View {
        let profiles: [ServerProfile]
        let recorder: Recorder
        @State private var selectedID: UUID?

        var body: some View {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(profiles) { profile in
                        ServerRow(profile: profile,
                                  query: "",
                                  isSelected: selectedID == profile.id,
                                  groupColor: nil,
                                  onTap: {
                                      selectedID = profile.id
                                      recorder.tapped.append(profile.name)
                                  },
                                  onDoubleTap: { recorder.opened.append(profile.name) })
                    }
                }
            }
            .frame(width: 520, height: 400)
        }
    }

    private func mount(_ profiles: [ServerProfile], recorder: Recorder) throws -> NSHostingView<AnyView> {
        let size = NSSize(width: 520, height: 400)
        let host = NSHostingView(rootView: AnyView(RowHarness(profiles: profiles, recorder: recorder)))
        host.frame = NSRect(origin: .zero, size: size)
        // 判据是结构 / 行为，不是时间 —— 走屏外档。
        let window = ProbeWindow.make(contentRect: NSRect(origin: .zero, size: size),
                                      styleMask: [.titled],
                                      contentView: host,
                                      key: true,
                                      placement: .offScreen)
        windows.append(window)
        ProbeWindow.isolateHostWindows(keeping: windows)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        return host
    }

    private static func profiles(_ n: Int) -> [ServerProfile] {
        WelcomeServerListCostTests.makeProfiles(count: n, groups: 2)
    }

    /// 在真 AX 树里按 label 找元素。**必须走 `AnyObject` 动态派发**：SwiftUI 的
    /// 懒栈把行挂在 `AccessibilityLazyLayoutNode` 下，那是个只实现 informal
    /// protocol 的 ObjC 对象，`as? any NSAccessibilityProtocol` 转不过去。
    private func axElement(_ label: String, in root: NSView) throws -> AnyObject {
        var out: AnyObject?
        var visited = 0
        func find(_ node: Any) {
            guard out == nil, visited < 20_000 else { return }
            visited += 1
            let element = node as AnyObject
            if element.accessibilityLabel?()?.contains(label) == true { out = element; return }
            for child in (element.accessibilityChildren?() ?? []) { find(child) }
            if out == nil, let view = node as? NSView {
                for child in view.subviews { find(child) }
            }
        }
        find(root)
        return try XCTUnwrap(out, "真实 AX 树找不到 \(label)")
    }

    private func settle(_ host: NSView) {
        for _ in 0..<20 { _ = RunLoop.current.run(mode: .default, before: .distantPast) }
        host.layoutSubtreeIfNeeded()
    }

    // MARK: - ① AX：label / trait / 默认动作

    /// 行不再是 `Button`，AX 语义必须完整补回：label 念得出「名称，端点」，
    /// 带 `AXButton` 角色，且默认动作（press）真的能选中。
    func testRowExposesAccessibilityLabelRoleAndPressAction() throws {
        defer { closeAllWindows() }
        let recorder = Recorder()
        let list = Self.profiles(12)
        let host = try mount(list, recorder: recorder)

        let target = list[3]
        let element = try axElement(target.name, in: host)

        let label = try XCTUnwrap(element.accessibilityLabel?() as String?)
        XCTAssertTrue(label.contains(target.name), "AX label 必须念出主机名：\(label)")
        XCTAssertTrue(label.contains(target.displayEndpoint),
                      "AX label 必须念出端点（换掉 Button 后 children:.combine 的内容不会自动回来）：\(label)")
        XCTAssertEqual(element.accessibilityRole?(), .button,
                       "行必须仍然是 AXButton —— VoiceOver 靠它决定「可按」")

        let pressed = element.accessibilityPerformPress?() ?? false
        settle(host)
        XCTAssertTrue(pressed, "AX 默认动作必须被实现（换掉 Button 后要手工补 accessibilityAction）")
        XCTAssertEqual(recorder.tapped, [target.name],
                       "AX press 必须走到 onTap（= 选中这一行）")
    }

    /// 双击「打开」在 AX 下也要按得到 —— 否则全键盘控制的用户永远连不上主机。
    func testRowExposesNamedOpenAccessibilityAction() throws {
        defer { closeAllWindows() }
        let recorder = Recorder()
        let list = Self.profiles(12)
        let host = try mount(list, recorder: recorder)

        let target = list[5]
        let element = try axElement(target.name, in: host)
        print("[ax-dump] class=\(type(of: element)) "
              + "actionNames=\(element.accessibilityActionNames?() ?? []) "
              + "custom=\((element.accessibilityCustomActions?() ?? []).map(\.name))")

        // SwiftUI 的 `.accessibilityAction(named:)` 在 AppKit 侧落成
        // `NSAccessibilityCustomAction`（不是 `accessibilityActionNames` 里的
        // 标准动作名 —— 那里只有 AXPress / AXScrollToVisible）。
        let custom = element.accessibilityCustomActions?() ?? []
        let open = try XCTUnwrap(custom.first { $0.name.contains("打开") },
                                 "行必须暴露「打开」这个具名 AX 动作（双击的等价路径）："
                                 + "custom=\(custom.map(\.name)) "
                                 + "standard=\(element.accessibilityActionNames?() ?? [])")

        _ = open.handler?()
        settle(host)
        XCTAssertEqual(recorder.opened, [target.name],
                       "具名动作「打开」必须走到 onDoubleTap")
    }

    /// 选中态必须进 AX（`.isSelected`）—— 视觉上的底色对 VoiceOver 不存在。
    func testSelectedRowIsMarkedSelectedInAccessibilityTree() throws {
        defer { closeAllWindows() }
        let recorder = Recorder()
        let list = Self.profiles(12)
        let host = try mount(list, recorder: recorder)

        let target = list[2]
        _ = try axElement(target.name, in: host).accessibilityPerformPress?()
        settle(host)

        let element = try axElement(target.name, in: host)
        XCTAssertTrue(element.isAccessibilitySelected?() ?? false,
                      "选中的行必须带 AX selected 标记")
    }

    // MARK: - ② 源码形态闸门

    /// 换掉 `Button` 是有账的（每行一个 `_FocusRingView` + `KeyViewProxy`，
    /// 见 `WelcomeServerListCostTests`）。这条闸门守住形态不回退，
    /// 同时守住「换掉之后必须补 AX」这条配套义务。
    ///
    /// **单 / 双击这一条改成钉行为，不钉源码字符串**：鼠标点击已从行里搬到
    /// `ServerList` 的容器级 `clickToSelect` —— 行里两个 `onTapGesture` 链式会让
    /// SwiftUI 等满系统双击间隔才发单击（实测点一行 390~510ms 才高亮，用户报的
    /// 就是这个）。行里因此**不该**再有任何 `onTapGesture`；「按下即选中、第二下
    /// 才连接」由 `ClickSelectActivateTests` 用真 `NSEvent` 断言。
    func testServerRowKeepsHandWrittenAccessibilityAndNoTapGesture() throws {
        let source = try String(contentsOf: Self.repoRoot.appendingPathComponent(
            "uTerm/Features/Welcome/Views/ServerRow.swift"), encoding: .utf8)

        XCTAssertFalse(source.contains("Button(action: onTap)"),
                       "行不能包回 Button —— 每行会多出一个 _FocusRingView + KeyViewProxy")
        XCTAssertFalse(source.contains(".onTapGesture"),
                       "行里不能再挂点击手势 —— 单 / 双击互斥消歧会让单击延迟半秒；"
                       + "鼠标点击走 ServerList 的 clickToSelect 容器层")
        XCTAssertTrue(source.contains(".accessibilityAction { onTap() }"),
                      "不是 Button 就必须手工补默认动作")
        XCTAssertTrue(source.contains("accessibilityAddTraits(isSelected ? [.isButton, .isSelected]"),
                      "AX 角色与选中态必须手工补")
        XCTAssertFalse(source.contains("@FocusState"))
        XCTAssertFalse(source.contains(".focusable("))
    }

    /// 容器层接线仍在：`ServerList` 必须给整个 `LazyVStack` 装上点击层，
    /// 且第二下真的走「连接」。
    func testServerListWiresContainerClickLayer() throws {
        let source = try String(contentsOf: Self.repoRoot.appendingPathComponent(
            "uTerm/Features/Welcome/Views/ServerList.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains(".clickToSelect("), "整列表一个容器级点击层")
        XCTAssertTrue(source.contains("onContextAction(.connect, profile)"),
                      "第二下必须走连接")
    }

    /// 常驻 `.help` 收成悬停门控（`NSToolTipManager` 每个滚动 tick 全量重算全窗
    /// tooltip 区域）。注意：这一刀在 `WelcomeServerListCostTests` 里量不到收益 ——
    /// 合成事件驱动不了 tooltip 管理器，理由写在那个探针的类注释里。
    func testServerRowTooltipsAreHoverGated() throws {
        let source = try String(contentsOf: Self.repoRoot.appendingPathComponent(
            "uTerm/Features/Welcome/Views/ServerRow.swift"), encoding: .utf8)

        XCTAssertFalse(source.contains(".help(profile.name)"))
        XCTAssertFalse(source.contains(".help(profile.displayEndpoint)"))
        XCTAssertTrue(source.contains(".help(whenHovering: hover, profile.name)"))
        XCTAssertTrue(source.contains(".help(whenHovering: hover, profile.displayEndpoint)"))
    }

    /// 相对时间格式化器必须是共享实例：`ServerRow` 逐行调用它。
    func testWelcomeRelativeFormatterIsShared() {
        let now = Date()
        let a = WelcomeFormat.relative(now.addingTimeInterval(-7200))
        let b = WelcomeFormat.relative(now.addingTimeInterval(-7200))
        XCTAssertEqual(a, b, "共享格式化器的输出必须稳定")
        XCTAssertEqual(WelcomeFormat.relative(nil), "从未")

        let source = try? String(contentsOf: Self.repoRoot.appendingPathComponent(
            "uTerm/Features/Welcome/Views/WelcomeComponents.swift"), encoding: .utf8)
        XCTAssertNotNil(source)
        XCTAssertFalse(source?.contains("let formatter = RelativeDateTimeFormatter()") ?? true,
                       "别在 relative(_:) 里现建格式化器 —— 它是逐行调用的")
    }

    // MARK: - ③ 右键 / 拖拽 / 键盘导航契约仍在

    /// 右键菜单、行拖拽、重排 drop delegate 三样在 `ServerList` 里的接线不能掉。
    func testServerListKeepsContextMenuDragAndReorderWiring() throws {
        let source = try String(contentsOf: Self.repoRoot.appendingPathComponent(
            "uTerm/Features/Welcome/Views/ServerList.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains(".contextMenu { contextMenu(for: profile) }"), "右键菜单")
        XCTAssertTrue(source.contains("ServerRowDragModifier"), "行拖拽")
        XCTAssertTrue(source.contains("ServerRowReorderDropDelegate"), "拖拽重排")
        XCTAssertTrue(source.contains("content.onDrag {"), "onDrag 仍是拖拽入口")
        XCTAssertTrue(source.contains("LazyVStack"), "列表必须是懒栈")
    }

    /// 键盘导航（↑↓ / ⌘↑↓ / ⌘E / ⌘⌫ / ⌘D）的键位映射不受行渲染方式影响 ——
    /// 它挂在窗口级监听上，不在行里。这条只是把「换行渲染没碰到键盘路径」钉住。
    func testListKeyboardNavigationMappingSurvives() {
        XCTAssertEqual(WelcomeKeymap.listAction(keyCode: 125, chars: "", command: false,
                                                option: false, control: false,
                                                isTextEditing: false), .next)
        XCTAssertEqual(WelcomeKeymap.listAction(keyCode: 126, chars: "", command: false,
                                                option: false, control: false,
                                                isTextEditing: false), .prev)
        XCTAssertEqual(WelcomeKeymap.listAction(keyCode: 126, chars: "", command: true,
                                                option: false, control: false,
                                                isTextEditing: false), .first)
        XCTAssertEqual(WelcomeKeymap.listAction(keyCode: 125, chars: "", command: true,
                                                option: false, control: false,
                                                isTextEditing: false), .last)
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
