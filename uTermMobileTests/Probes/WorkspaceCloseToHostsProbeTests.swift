import SwiftData
import SwiftUI
import UIKit
import XCTest
@testable import uTermMobile

/// 工作区（终端 / Code 标签页）整层滑回主机列表、或从主机列表滑出来的那 0.28 秒：逐拍记显示节拍的间隔，
/// 主线程卡住时抄调用栈，看是谁占了那几拍。
///
/// 挂的是和 App 同一个外壳（`MobileTabShell` + `WorkspaceLayer`），终端是真的 Ghostty surface（输出走假 SSH 后端），
/// Code 标签页接假的文件树，主机用 `.realistic`（100 台，在 `HostsScreen.eagerHostLimit` 以内、卡片不懒加载）。
/// 关标签走 `store.teardownTabIDs`——和标签条关闭钮同一套收尾（断连、清理、收回主机列表）。
///
/// 实测报的问题（2026-11-26）：终端、Code 标签页整个关掉回到主机列表时掉帧。改前读数（iPhone 18 Pro 模拟器，60 Hz）：
/// Code 最长一拍 116 ms、终端 67–95 ms，都在滑动的头一拍。不挂主机页时关标签一帧不掉——是主机页那一侧：
/// 它的 `body` 读着工作区（工具栏「标签页 N」），标签一没整页 100 张卡片重建；工具栏少了一个按钮，系统又把整页重排一遍。
/// Duo 真机上（120 Hz）另有两笔：标签当场摘下、工作区各格重算（~27 ms），摘下的视图在收起动画末尾才拆（~63 ms）——
/// 改成先收起、滑完再摘（`WorkspaceScreen.close(_:then:)`）。读数里每一拍记成「距动作 ms / 这一拍 ms」（after-action）。
/// 点「标签页 N」滑回终端：终端在滑动的头几拍拿第一响应者、起键盘会话（模拟器 486 ms、Duo 123 + 111 ms）——改成滑完再聚焦。
@MainActor
final class WorkspaceCloseToHostsProbeTests: XCTestCase {

    private enum Kind { case terminal, code }

    private struct Reading {
        let intervals: [Double]
        let nominal: Double
        let stalls: [String]
        /// 动作之后、到滑动结束（`WorkspaceLayer.slideSettleSeconds`）为止的每一拍。判定只看这一段：
        /// 滑完之后的活（真关标签、终端起键盘）没有东西在动，不算掉帧。
        let slide: [Double]

        var longest: Double { slide.max() ?? 0 }
    }

    private struct Rig {
        let window: UIWindow
        let store: MobileStore
        let workspace: MobileWorkspace
        let host: ServerProfile
        let tabID: UUID
        let controller: MobileTerminalController?
    }

    func testClosingLastTerminalTabSlidesBackWithoutDroppingFrames() async throws {
        defer { MobileProbeWindow.closeAll() }
        let rig = try await mount(.terminal)
        let reading = try await measure("close-terminal") { rig.store.teardownTabIDs = [rig.tabID] }
        try await assertClosed(rig)
        XCTAssertEqual(rig.workspace.tabs.count, 0)
        assertSmooth(reading, label: "关终端")
    }

    func testClosingLastCodeTabSlidesBackWithoutDroppingFrames() async throws {
        defer { MobileProbeWindow.closeAll() }
        let rig = try await mount(.code)
        let reading = try await measure("close-code") { rig.store.teardownTabIDs = [rig.tabID] }
        try await assertClosed(rig)
        assertSmooth(reading, label: "关 Code")
    }

    /// 收起之后点「标签页 N」回去：工作区带着原来的终端滑回来，键盘不自动弹（拿键盘加终端变矮重排压在滑进来之后
    /// 那一拍上，实机觉得卡；用户点终端再要）。
    func testExpandingBackToTerminalSlidesInWithoutDroppingFrames() async throws {
        defer { MobileProbeWindow.closeAll() }
        let rig = try await mount(.terminal)
        // 和 App 里一样：之前在这个终端里打过字（键盘会话起过一次）。第一次起键盘的冷启动（测试进程里两百多 ms）不算在这里。
        let view = try XCTUnwrap(rig.controller?.terminal.view)
        // 夹具开局就是展开的，没走过一次展开：收起再展开一次，键盘归属才落到这个终端上。
        rig.store.showWorkspace = false
        try await Task.sleep(for: .milliseconds(600))
        rig.store.showWorkspace = true
        try await Task.sleep(for: .milliseconds(600))
        rig.controller?.showKeyboard()
        let warmed = await MobileFakeTerminal.waitUntil(timeout: .seconds(3)) { view.isFirstResponder }
        XCTAssertTrue(warmed, "用户要了键盘，终端要拿到")
        try await Task.sleep(for: .milliseconds(800))
        rig.store.showWorkspace = false
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertFalse(view.isFirstResponder, "收起时要收键盘")
        let reading = try await measure("expand-terminal") { rig.store.showWorkspace = true }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(view.isFirstResponder, "回到工作区不自动弹键盘")
        // 滑进来的头一两拍还有终端自己的「换回盖子」（拷上一帧防闪，`GhosttySwitchBackCover`）与补画：
        // Duo 31 ms，模拟器 30–55 ms。这里只拦大卡顿（改前起键盘那一下 Duo 123 + 111 ms、模拟器 486 ms）。
        assertSmooth(reading, label: "回终端", budgetFrames: 6)
        // 点一下要回来照常给。
        rig.controller?.showKeyboard()
        let focused = await MobileFakeTerminal.waitUntil(timeout: .seconds(2)) { view.isFirstResponder }
        XCTAssertTrue(focused, "回来后用户要键盘照常给")
    }

    func testExpandingBackToCodeSlidesInWithoutDroppingFrames() async throws {
        defer { MobileProbeWindow.closeAll() }
        let rig = try await mount(.code)
        rig.store.showWorkspace = false
        try await Task.sleep(for: .milliseconds(800))
        let reading = try await measure("expand-code") { rig.store.showWorkspace = true }
        assertSmooth(reading, label: "回 Code")
    }

    /// 反方向：从主机列表打开第一个标签，工作区滑出来（改前工具栏那颗按钮同样在这一拍出现）。
    func testOpeningFirstTabSlidesInWithoutDroppingFrames() async throws {
        defer { MobileProbeWindow.closeAll() }
        let rig = try await mount(nil)
        let reading = try await measure("open-code") {
            let history = rig.workspace.openHistory(
                MobileFakeClaudeHistory.tab(host: rig.host, tree: MobileClaudeFixture.standard()))
            rig.workspace.activate(history.id)
            rig.store.showWorkspace = true
        }
        assertSmooth(reading, label: "开 Code")
    }

    /// 「标签页 N」按钮推迟到工作区滑完才改，但不能丢：工作区盖着时不出，收起后出现、数对，关完最后一个后消失。
    func testReturnButtonAppearsAfterCollapseAndGoesAwayWithLastTab() async throws {
        defer { MobileProbeWindow.closeAll() }
        let rig = try await mount(.code)
        let label = "标签页 1"
        XCTAssertFalse(trailingTitles(in: rig.window).contains(label), "工作区盖着时不该动工具栏")

        rig.store.showWorkspace = false
        let shown = await MobileFakeTerminal.waitUntil(timeout: .seconds(3)) {
            self.trailingTitles(in: rig.window).contains(label)
        }
        XCTAssertTrue(shown, "收起工作区后工具栏要有「\(label)」：\(trailingTitles(in: rig.window))")

        rig.store.showWorkspace = true
        try await Task.sleep(for: .milliseconds(200))
        rig.store.teardownTabIDs = [rig.tabID]
        let gone = await MobileFakeTerminal.waitUntil(timeout: .seconds(3)) {
            !self.trailingTitles(in: rig.window).contains(label)
        }
        XCTAssertTrue(gone, "关完最后一个标签，「标签页」按钮要消失：\(trailingTitles(in: rig.window))")
    }

    // MARK: - 夹具

    /// `kind` 为 nil：不开标签，停在主机列表上。
    private func mount(_ kind: Kind?) async throws -> Rig {
        let container = try MobileFixtures.modelContainer(seed: .realistic)
        let host = try XCTUnwrap(MobileFixtures.firstServer(in: container))
        let relay = HostKeyChallengeRelay()
        let store = MobileStore()
        store.tab = .hosts
        let workspace = MobileWorkspace()

        var tabID = UUID()
        var controller: MobileTerminalController?
        switch kind {
        case .terminal:
            let script = MobileFakeTerminalScript(linesPerSecond: 0, seconds: 0, corpus: .plain)
            let (tab, _) = MobileFakeTerminal.tab(host: host, script)
            workspace.open(.terminal(tab))
            tabID = tab.id
            controller = tab.controller
            tab.controller.start(profile: host, container: container, relay: relay)
        case .code:
            tabID = workspace.openHistory(MobileFakeClaudeHistory.tab(host: host, tree: MobileClaudeFixture.standard())).id
        case nil:
            break
        }
        if kind != nil {
            workspace.activate(tabID)
            store.showWorkspace = true
        }

        let lan = LANSyncCoordinator(role: .receiver, preferences: SharedPreferencesSync(),
                                     dataStore: LANSyncDataStore(container: container))
        let root = ZStack {
            MobileTabShell()
            WorkspaceLayer()
        }
        .mMeasuresChrome()
        .environment(store)
        .environment(workspace)
        .environment(relay)
        .environment(TerminalActivityCenter())
        .environment(lan)
        .environment(RemoteMacDirectory(identity: RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage())))
        .environment(CloudKitSyncMonitor())
        .environment(\.mAccent, M.accent)
        .modelContainer(container)
        let (window, hosting) = MobileProbeWindow.make(placement: .visibleOnScreen, rootView: root)
        hosting.safeAreaRegions = .all
        window.makeKeyAndVisible()

        if let controller {
            let connected = await MobileFakeTerminal.waitUntilConnected(controller)
            XCTAssertTrue(connected)
            let bridge = controller.terminal
            let ready = await MobileFakeTerminal.waitUntil(timeout: .seconds(5)) {
                bridge.view.surface != nil && bridge.grid != nil && bridge.isSurfaceReady && bridge.outputPump.isFeedingSurface
            }
            XCTAssertTrue(ready, "Ghostty surface 没建起来")
        } else if let history = workspace.tab(tabID)?.history {
            let settled = await MobileFakeClaudeHistory.settle(history)
            XCTAssertTrue(settled)
        }
        try await Task.sleep(for: .milliseconds(1_200))
        return Rig(window: window, store: store, workspace: workspace, host: host, tabID: tabID, controller: controller)
    }

    /// 动作前后各留一段，逐拍记间隔；主线程一轮忙过 8 ms 就抄栈。
    private func measure(_ label: String, _ action: () -> Void) async throws -> Reading {
        let counter = DisplayLinkCounter()
        let sampler = MainThreadStallSampler(threshold: 0.008, interval: 0.004)
        counter.start()
        try await Task.sleep(for: .milliseconds(300))
        sampler.start()
        let origin = CACurrentMediaTime()
        let ticksBefore = counter.intervals.count
        action()
        try await Task.sleep(for: .milliseconds(900))
        sampler.stop()
        counter.stop()

        let samples = sampler.drain()
        let stalls = sampler.report(samples, origin: origin, depth: 96, limit: 6)
        var elapsed = 0.0
        let slide = counter.intervals.dropFirst(ticksBefore).filter { interval in
            defer { elapsed += interval }
            return elapsed < WorkspaceLayer.slideSettleSeconds * 1000
        }
        let reading = Reading(intervals: counter.intervals, nominal: counter.nominalIntervalMS, stalls: stalls, slide: slide)
        print(String(format: "[close-to-hosts] %@ nominal=%.2fms longest-in-slide=%.1fms intervals=%@", label,
                     reading.nominal, reading.longest,
                     reading.intervals.map { String(format: "%.0f", $0) }.joined(separator: ",")))
        // 动作之后每一拍：距动作的时刻 / 这一拍的间隔。
        var t = 0.0
        let after = counter.intervals.dropFirst(ticksBefore).map { interval -> String in
            t += interval
            return String(format: "%.0f/%.0f", t, interval)
        }
        print("[close-to-hosts] \(label) after-action " + after.prefix(50).joined(separator: " "))
        for line in stalls { print("[close-to-hosts] \(label) stall \(line)") }
        // 每份栈里属于 App 自己的帧（叶子在前），事后 `xcrun swift-demangle` 看是哪段代码。
        for sample in samples {
            let own = sample.frames.map(MainThreadStallSampler.symbol).filter { $0.hasPrefix("uTermMobile") }
            print(String(format: "[close-to-hosts] %@ own @%.0fms+%.0f: ", label, sample.busyMS, (sample.time - origin) * 1000)
                  + own.prefix(12).joined(separator: " < "))
        }
        return reading
    }

    /// 收回了主机列表，标签在滑完之后真的摘下（终端断开）。
    private func assertClosed(_ rig: Rig) async throws {
        XCTAssertFalse(rig.store.showWorkspace, "关了最后一个标签应回到主机列表")
        let removed = await MobileFakeTerminal.waitUntil(timeout: .seconds(2)) { rig.workspace.isEmpty }
        XCTAssertTrue(removed, "滑完之后标签要摘下")
        XCTAssertTrue(rig.workspace.closingTabIDs.isEmpty)
        if let controller = rig.controller {
            XCTAssertEqual(controller.state, .disconnected, "关掉的终端要断开")
        }
    }

    private func assertSmooth(_ reading: Reading, label: String, budgetFrames: Double = 2.5) {
        // 只拦用户看得出的一顿：一拍占掉两拍半以上（60 Hz 42 ms / 120 Hz 21 ms）。一两拍的抖动机器忙时也会有。
        XCTAssertLessThan(reading.longest, reading.nominal * budgetFrames,
                          "\(label)：最长一拍 \(Int(reading.longest)) ms（标称 \(String(format: "%.1f", reading.nominal)) ms）\n"
                          + reading.stalls.prefix(4).joined(separator: "\n"))
    }

    /// 主机页导航栏右侧按钮的标题（SwiftUI 的 `ToolbarItemGroup` 落到 `UINavigationItem` 上）。
    private func trailingTitles(in window: UIWindow) -> [String] {
        func all(_ vc: UIViewController) -> [UIViewController] { [vc] + vc.children.flatMap(all) }
        guard let root = window.rootViewController else { return [] }
        return all(root)
            .flatMap { $0.navigationItem.trailingItemGroups.flatMap(\.barButtonItems) }
            .compactMap { $0.title ?? $0.accessibilityLabel }
    }
}
