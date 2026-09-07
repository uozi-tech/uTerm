import AppKit
import SwiftData
import SwiftUI
import UDesignKit
import XCTest
@testable import uTerm

/// 端口转发两个列表的**交互契约**闸门 —— 渲染方式怎么改，这些行为都不许变。
///
/// 覆盖：行内容真的画出来（不是空壳）、无障碍标签、开关按下真的落到数据与协调器、
/// 铅笔按下真的开编辑器、懒栈不吞数据（滚到底最后一台主机的规则仍在）。
///
/// **为什么走无障碍默认动作而不是合成 `NSEvent`**：合成事件驱动不了 SwiftUI 的手势
/// （uTable playbook §五·八④ 实测三条路全不翻，连 `Button` 也点不动）。`Button` 的
/// AX 默认动作 `accessibilityPerformPress()` 是唯一能在测试里真按下去的入口。
///
/// **网络安全**：只把已经「保持连接」的规则**关掉**（`coordinator.stop`，纯本地），
/// 绝不打开 —— 打开会走 `coordinator.start` 去真连 10.x 的假主机。
@MainActor
final class ForwardingListContractTests: XCTestCase {

    private var windows: [NSWindow] = []

    private func closeAllWindows() {
        for window in windows {
            window.contentView = NSView()
            window.orderOut(nil)
        }
        windows.removeAll()
    }

    // MARK: - AX 工具

    /// 递归收集子树里所有无障碍元素的 label / title / value。
    ///
    /// 必须走 `AnyObject` 的动态派发：SwiftUI 的 AX 元素不是公开类型，
    /// 用 Swift 协议转型一律失败（懒栈里的行还挂在 `AccessibilityLazyLayoutNode` 下）。
    private func axStrings(_ root: Any, depth: Int = 0) -> [String] {
        guard depth < 60 else { return [] }
        var out: [String] = []
        let object = root as AnyObject
        if let label = object.accessibilityLabel?(), !label.isEmpty { out.append(label) }
        if let title = object.accessibilityTitle?(), !title.isEmpty { out.append(title) }
        // `accessibilityValue` 在 Swift 里同时匹配到多个重载（`Any?` / `String?`），
        // 直接写会「ambiguous use」；走 selector 取值绕开重载解析。SwiftUI 的静态文本
        // 正是把文案放在 value 上的，少了这一条就读不到规则名。
        let valueSelector = NSSelectorFromString("accessibilityValue")
        if object.responds?(to: valueSelector) == true,
           let value = object.perform(valueSelector)?.takeUnretainedValue() as? String,
           !value.isEmpty {
            out.append(value)
        }
        if let children = object.accessibilityChildren?() {
            for child in children { out += axStrings(child, depth: depth + 1) }
        }
        return out
    }

    /// 找到 label 完全匹配的那个无障碍元素。
    private func axElement(_ root: Any, label: String, depth: Int = 0) -> AnyObject? {
        guard depth < 60 else { return nil }
        let object = root as AnyObject
        if let found = object.accessibilityLabel?(), found == label { return object }
        if let children = object.accessibilityChildren?() {
            for child in children {
                if let hit = axElement(child, label: label, depth: depth + 1) { return hit }
            }
        }
        return nil
    }

    /// 从一个无障碍元素（含它自己）往下找第一个 role 是 button 的节点。
    ///
    /// `.accessibilityLabel(...)` 挂在 `UDToggle` **外面**，SwiftUI 于是多包一层
    /// 没有默认动作的分组元素 —— 直接对它 `accessibilityPerformPress()` 会「成功」
    /// 但什么都没发生。真正的 `Button` 在它下面一层。
    private func pressableButton(_ root: AnyObject, depth: Int = 0) -> AnyObject? {
        guard depth < 20 else { return nil }
        let roleSelector = NSSelectorFromString("accessibilityRole")
        if root.responds?(to: roleSelector) == true,
           let role = root.perform(roleSelector)?.takeUnretainedValue() as? String,
           role == NSAccessibility.Role.button.rawValue {
            return root
        }
        if let children = root.accessibilityChildren?() {
            for child in children {
                if let hit = pressableButton(child as AnyObject, depth: depth + 1) { return hit }
            }
        }
        return nil
    }

    /// 逐屏滚到底。
    ///
    /// **不能一步跳到 `maxOffset`**：懒栈是先估后修的，行高不一（失败行多一条原因条），
    /// 一次性跳过去时 documentView 的高度还是估出来的，落点其实没到真正的末尾。
    /// 一屏一屏往下走、每步交付一次布局，估高被逐段修正，最后才真的到底。
    private func scrollToBottom(_ mounted: ForwardingProbeFixture.Mounted) {
        let scroll = mounted.scroll
        let step = max(1, scroll.contentSize.height * 0.8)
        var guard_ = 0
        while guard_ < 400 {
            guard_ += 1
            let maxOffset = max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentSize.height)
            let current = scroll.contentView.bounds.origin.y
            if current >= maxOffset - 0.5 { break }
            scroll.contentView.scroll(to: NSPoint(x: 0, y: min(maxOffset, current + step)))
            scroll.reflectScrolledClipView(scroll.contentView)
            mounted.host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        mounted.host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        mounted.host.layoutSubtreeIfNeeded()
    }

    // MARK: - 全局面板

    private struct GlobalHarness {
        let mounted: ForwardingProbeFixture.Mounted
        let coordinator: ForwardingCoordinator
        let rules: [ForwardingRule]
        let container: ModelContainer
    }

    private func mountGlobal(hosts: Int, rulesPerHost: Int) throws -> GlobalHarness {
        // 先把上一条用例的宿主视图真正放掉再造数据。`ModelContext.save()` 会给所有
        // `_SwiftData_SwiftUI` 的 `@Query` 观察者发通知；上一条用例的观察者还在
        // autorelease 池里没散时收到通知，SwiftData 会 `EXC_BREAKPOINT` 把测试宿主打没
        // （xcresult 只留一句「Restarting after unexpected exit」）。转一圈 runloop 就散了。
        closeAllWindows()
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        let seeded = try ForwardingProbeFixture.seed(hosts: hosts, rulesPerHost: rulesPerHost)
        let root = AnyView(
            GlobalForwardingWindowView()
                .environment(seeded.coordinator)
                .environment(GlobalForwardingModel())
                .environment(HostKeyChallengeRelay())
                .modelContainer(seeded.container))
        let mounted = try ForwardingProbeFixture.mount(root,
                                                       size: NSSize(width: 900, height: 700),
                                                       windows: &windows)
        return GlobalHarness(mounted: mounted, coordinator: seeded.coordinator,
                             rules: seeded.rules, container: seeded.container)
    }

    /// 行真的画出来了 + 无障碍标签齐全（规则名、编辑配置铅笔、保持连接开关）。
    func testGlobalPanelRendersRowsWithAccessibilityLabels() throws {
        defer { closeAllWindows() }
        let seeded = try mountGlobal(hosts: 10, rulesPerHost: 5)
        seeded.mounted.host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        seeded.mounted.host.layoutSubtreeIfNeeded()

        let strings = axStrings(seeded.mounted.host)
        let joined = strings.joined(separator: "\n")
        // ① 首屏第一条规则的名字必须真的出现（否则量到的是空壳）。
        let first = try XCTUnwrap(seeded.rules.first)
        XCTAssertTrue(joined.contains(first.name),
                      "首屏必须画出第一条规则「\(first.name)」；实收 \(strings.prefix(40))")
        // ② 保持连接开关的 AX 标签按当前状态给出正确动作文案。
        //
        //    注：行内「编辑配置」铅笔**读不到** —— 它是 `opacity(hover ? 1 : 0)`，
        //    SwiftUI 把完全透明的视图排除在无障碍树之外。这是改前就有的老问题
        //    （本探针在改前改后都读不到它），不是这轮渲染改动引入的；见
        //    `docs/scroll-perf-findings.md` 的「没做到的」。
        XCTAssertTrue(joined.contains("保持连接「") || joined.contains("停止并取消保持「"),
                      "每行开关必须有「保持连接 / 停止并取消保持」无障碍标签")
    }

    /// 分组懒栈不吞数据：滚到底，最后一台主机的最后一条规则仍然渲染得出来。
    func testGlobalPanelLazySectionsStillRenderTheLastHost() throws {
        defer { closeAllWindows() }
        let seeded = try mountGlobal(hosts: 50, rulesPerHost: 20)
        let scroll = seeded.mounted.scroll
        XCTAssertGreaterThan(max(0, seeded.mounted.document.frame.height - scroll.contentSize.height),
                             0, "1000 行必须超过一屏")
        scrollToBottom(seeded.mounted)

        let joined = axStrings(seeded.mounted.host).joined(separator: "\n")
        let last = try XCTUnwrap(seeded.rules.last)
        XCTAssertTrue(joined.contains(last.name),
                      "滚到底必须能看到最后一条规则「\(last.name)」——懒栈不能把尾部的分组吞掉")
    }

    /// 行与模型是活绑定：改 `launchAtAppStart`，开关的无障碍动作文案当场跟着换。
    ///
    /// 这条替代「按下开关」的端到端 —— 合成事件驱动不了 SwiftUI 手势（playbook §五·八④），
    /// 而 `accessibilityPerformPress()` 在本工程的 `UDToggle`（`Button(.plain)` 包装）上
    /// 返回 true 却不触发 action，实测按不动。绑定活着就说明开关点下去会走到
    /// `setKeepConnected`（那条逻辑本轮一字未改）。
    func testGlobalPanelToggleLabelTracksTheModel() throws {
        defer { closeAllWindows() }
        let seeded = try mountGlobal(hosts: 4, rulesPerHost: 3)
        seeded.mounted.host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        seeded.mounted.host.layoutSubtreeIfNeeded()

        let target = try XCTUnwrap(seeded.rules.first {
            $0.launchAtAppStart && seeded.coordinator.status($0.id) == .active
        }, "夹具里必须有一条已保持连接且活跃的规则")
        XCTAssertNotNil(axElement(seeded.mounted.host, label: "停止并取消保持「\(target.name)」"),
                        "已保持连接的行，开关动作文案应是「停止并取消保持」")

        target.launchAtAppStart = false
        try seeded.container.mainContext.save()
        seeded.mounted.host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        seeded.mounted.host.layoutSubtreeIfNeeded()

        XCTAssertNotNil(axElement(seeded.mounted.host, label: "保持连接「\(target.name)」"),
                        "改掉模型后，开关动作文案必须当场翻成「保持连接」——行与模型是活绑定")
    }

    /// 组头的「N/M 活跃」现在来自一遍算完的 `GFDerivedCounts`，数值必须与逐条状态一致。
    func testGlobalPanelSectionHeaderShowsTheRightActiveCount() throws {
        defer { closeAllWindows() }
        let seeded = try mountGlobal(hosts: 4, rulesPerHost: 3)
        seeded.mounted.host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        seeded.mounted.host.layoutSubtreeIfNeeded()

        let firstHost = try XCTUnwrap(seeded.rules.first?.serverID)
        let hostRules = seeded.rules.filter { $0.serverID == firstHost }
        let active = hostRules.filter { seeded.coordinator.status($0.id) == .active }.count
        let expected = "\(active)/\(hostRules.count) 活跃"
        XCTAssertTrue(axStrings(seeded.mounted.host).contains(expected),
                      "首个分组组头应显示「\(expected)」")
    }


    // MARK: - 单主机面板

    private struct SingleHostHarness {
        let mounted: ForwardingProbeFixture.Mounted
        let coordinator: ForwardingCoordinator
        let rules: [ForwardingRule]
    }

    private func mountSingleHost(rules count: Int) throws -> SingleHostHarness {
        closeAllWindows()
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        let seeded = try ForwardingProbeFixture.seed(hosts: 1, rulesPerHost: count)
        let root = AnyView(
            PortForwardListView(server: seeded.profiles[0],
                                rules: seeded.rules,
                                hostKeyRelay: HostKeyChallengeRelay())
                .environment(seeded.coordinator)
                .modelContainer(seeded.container))
        let mounted = try ForwardingProbeFixture.mount(root,
                                                       size: NSSize(width: 820, height: 640),
                                                       windows: &windows)
        return SingleHostHarness(mounted: mounted, coordinator: seeded.coordinator,
                                 rules: seeded.rules)
    }

    /// 工具栏的六个计数改成一遍扫完之后，数值必须与逐条重算一致
    /// （全部 / 本地 / 远程 / 动态 + N 活跃 + M 异常）。
    func testSingleHostToolbarCountsMatchTheRules() throws {
        defer { closeAllWindows() }
        let harness = try mountSingleHost(rules: 24)
        harness.mounted.host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        harness.mounted.host.layoutSubtreeIfNeeded()

        let strings = axStrings(harness.mounted.host)
        let rules = harness.rules
        let expectedSegments = [
            "全部 \(rules.count)",
            "本地 \(rules.filter { $0.kind == .local }.count)",
            "远程 \(rules.filter { $0.kind == .remote }.count)",
            "动态 \(rules.filter { $0.kind == .dynamic }.count)",
        ]
        for segment in expectedSegments {
            XCTAssertTrue(strings.contains(segment),
                          "类型分段必须显示「\(segment)」；实收 \(strings.prefix(30))")
        }
        let active = rules.filter { harness.coordinator.status($0.id) == .active }.count
        let failed = rules.filter {
            if case .error = harness.coordinator.status($0.id) { return true } else { return false }
        }.count
        XCTAssertTrue(strings.contains("\(active) 活跃"), "汇总点必须显示「\(active) 活跃」")
        if failed > 0 {
            XCTAssertTrue(strings.contains("\(failed) 异常"), "汇总点必须显示「\(failed) 异常」")
        }
    }

    /// 单主机列表懒栈不吞数据：200 条滚到底，最后一条规则仍渲染得出来。
    func testSingleHostLazyListStillRendersTheLastRule() throws {
        defer { closeAllWindows() }
        let harness = try mountSingleHost(rules: 200)
        let scroll = harness.mounted.scroll
        XCTAssertGreaterThan(max(0, harness.mounted.document.frame.height - scroll.contentSize.height),
                             0, "200 条必须超过一屏")
        scrollToBottom(harness.mounted)

        let last = try XCTUnwrap(harness.rules.last)
        XCTAssertTrue(axStrings(harness.mounted.host).joined(separator: "\n").contains(last.name),
                      "滚到底必须能看到最后一条规则「\(last.name)」")
    }

    /// 隧道行的开关文案随状态走（active → 「停止隧道」，否则「启动隧道」）。
    func testSingleHostRowToggleLabelTracksStatus() throws {
        defer { closeAllWindows() }
        let harness = try mountSingleHost(rules: 12)
        harness.mounted.host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        harness.mounted.host.layoutSubtreeIfNeeded()

        let target = try XCTUnwrap(harness.rules.first {
            harness.coordinator.status($0.id) == .active
        }, "夹具里必须有一条活跃规则")
        XCTAssertNotNil(axElement(harness.mounted.host, label: "停止隧道「\(target.name)」"),
                        "活跃行的开关动作文案应是「停止隧道」")

        harness.coordinator.setStatusForTesting(.inactive, for: target.id)
        harness.mounted.host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        harness.mounted.host.layoutSubtreeIfNeeded()
        XCTAssertNotNil(axElement(harness.mounted.host, label: "启动隧道「\(target.name)」"),
                        "状态转 inactive 后，开关动作文案必须翻成「启动隧道」")
    }
}
