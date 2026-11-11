import GhosttyTerminal
import SwiftUI
import UIKit
import XCTest
@testable import uTermMobile

/// 容器与外壳切换、收起、取消的边界（基础规则与夹具见 `MTerminalContainerViewTests`）。
@MainActor
final class MTerminalContainerAdoptionTests: MTerminalContainerTestCase {
    // MARK: - 外壳切换

    /// 新容器尺寸不同：等停稳后终端跟上新容器，程序只收到一次通知。
    func testAdoptingContainerOfADifferentSizeCommitsAfterSettling() async throws {
        let (bridge, stale) = try await hostedInWindow()
        let before = await reported(bridge)
        let live = MTerminalContainerView(terminal: bridge, fontSize: 11)
        XCTAssertTrue(bridge.view.superview === live)
        try mount(live)

        lay(live, CGSize(width: 300, height: 500))
        XCTAssertEqual(bridge.view.frame.size, mounted, "已经排布过的终端也要等停稳")
        await settle()

        assertCommitted(bridge, CGSize(width: 300, height: 500))
        let after = await reported(bridge)
        XCTAssertNotEqual(after.grid, before.grid)
        XCTAssertEqual(after.count, before.count + 1)
        lay(stale, .zero)
        XCTAssertEqual(bridge.view.frame.size, CGSize(width: 300, height: 500), "旧容器不再摆放它")
    }

    /// 新容器尺寸相同（转屏来回、外壳切换）：程序什么都不该收到。
    func testAdoptingContainerOfTheSameSizeDoesNotReflow() async throws {
        let (bridge, _) = try await hostedInWindow()
        let before = await reported(bridge)
        let live = MTerminalContainerView(terminal: bridge, fontSize: 11)
        try mount(live)

        lay(live, mounted)
        await settle()

        XCTAssertEqual(bridge.view.frame.size, mounted)
        let after = await reported(bridge)
        XCTAssertEqual(after, before)
    }

    /// 旧容器等待期间被换掉：它的提交不能落到已被接走的终端上。
    func testPendingCommitOfAReplacedContainerIsDropped() async throws {
        let (bridge, stale) = try await hostedInWindow()
        let before = await reported(bridge)
        lay(stale, CGSize(width: 200, height: 300))
        let live = MTerminalContainerView(terminal: bridge, fontSize: 11)
        try mount(live)
        lay(live, mounted)

        await settle()

        assertCommitted(bridge, mounted)
        let after = await reported(bridge)
        XCTAssertEqual(after, before)
    }

    // MARK: - 收起与取消

    func testContainerExposedAgainAtANewSizeCommits() async throws {
        let (bridge, container) = try await hostedInWindow()
        let before = await reported(bridge)
        lay(container, .zero)
        await settle()

        lay(container, CGSize(width: 300, height: 400))
        await settle()

        XCTAssertEqual(bridge.view.frame.size, CGSize(width: 300, height: 400))
        let after = await reported(bridge)
        XCTAssertNotEqual(after.grid, before.grid)
        XCTAssertEqual(after.count, before.count + 1)
    }

    func testCancelledHoldNeverCommits() async throws {
        let (bridge, container) = try await hostedInWindow()
        let before = await reported(bridge)

        lay(container, CGSize(width: 200, height: 300))
        container.cancelHold()
        await settle()

        XCTAssertEqual(bridge.view.frame.size, mounted, "表示层拆掉之后不再动终端")
        let after = await reported(bridge)
        XCTAssertEqual(after, before)
    }

    // MARK: - 等待期间的摆放

    /// 键盘升起又收起：贴底的偏移要还原，不能留下错位的终端。
    func testRoundTripRestoresPosition() async {
        let (bridge, container) = await hosted()

        lay(container, CGSize(width: 400, height: 300))
        XCTAssertEqual(bridge.view.frame.minY, -300)
        lay(container, mounted)

        XCTAssertEqual(bridge.view.frame, CGRect(origin: .zero, size: mounted))
    }

    /// 容器变高（键盘收起）的等待期间贴顶，下面留白而不是跑到中间。
    func testHeldTerminalStaysAtTopWhenShorterThanContainer() async {
        let (bridge, container) = await hosted()

        lay(container, CGSize(width: 400, height: 800))

        XCTAssertEqual(bridge.view.frame.minY, 0)
        XCTAssertEqual(bridge.view.frame.height, mounted.height)
    }

    // MARK: - 字号

    func testFontRoundTripDoesNotReflow() async throws {
        let (bridge, container) = try await hostedInWindow()
        let before = await reported(bridge)

        container.setFontSize(9)
        container.setFontSize(11)
        await settle()

        XCTAssertEqual(bridge.view.terminalFontSize, 11, accuracy: 0.01)
        let after = await reported(bridge)
        XCTAssertEqual(after, before)
    }

    func testFontAloneCommitsAfterSettling() async throws {
        let (bridge, container) = try await hostedInWindow()
        let before = await reported(bridge)

        container.setFontSize(14)
        XCTAssertEqual(bridge.view.terminalFontSize, 11, accuracy: 0.01)
        await settle()

        XCTAssertEqual(bridge.view.terminalFontSize, 14, accuracy: 0.01)
        let after = await reported(bridge)
        XCTAssertNotEqual(after.grid, before.grid)
        XCTAssertEqual(after.count, before.count + 1)
    }

    // MARK: - SwiftUI 外壳切换全程

    @Observable final class Flag { var wide = true }

    private struct ShellSwap: View {
        let flag: Flag
        let controller: MobileTerminalController

        var body: some View {
            // 两个分支的结构身份不同：切换时 SwiftUI 拆掉旧表示层、新建一个，和外壳在标签栏 ⇄ 侧栏之间切换时一样。
            if flag.wide {
                HStack(spacing: 0) { MTerminalHostView(controller: controller, autoFocus: false) }.frame(width: 390, height: 500)
            } else {
                VStack(spacing: 0) { MTerminalHostView(controller: controller, autoFocus: false) }.frame(width: 300, height: 400)
            }
        }
    }

    private func waitUntilFed(_ terminal: GhosttyTerminalBridge, file: StaticString = #filePath, line: UInt = #line) async {
        let ready = await MobileFakeTerminal.waitUntil(timeout: .seconds(5)) {
            terminal.isSurfaceReady && terminal.outputPump.isFeedingSurface
        }
        XCTAssertTrue(ready, "surface 没就绪", file: file, line: line)
    }

    /// 尺寸经输入通道异步送到后端：等假传输的账本对上再读（最多 2 s，对不上就把最后读到的交给断言）。
    private func ledger(of transport: MobileFakeTerminalTransport,
                        until matches: (MobileFakeTerminalTransport.Ledger) -> Bool) async
        -> MobileFakeTerminalTransport.Ledger {
        let deadline = ContinuousClock.now + .seconds(2)
        var ledger = await transport.ledger
        while !matches(ledger), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
            ledger = await transport.ledger
        }
        return ledger
    }

    /// 外壳重建：同一个终端视图、内容不丢、连接不断，尺寸跟新容器走，PTY 收到的是最终尺寸。
    func testShellSwapKeepsTheTerminalAndFollowsTheNewSize() async throws {
        defer { MobileProbeWindow.closeAll() }
        let container = try MobileFixtures.modelContainer(seed: .smoke)
        let host = try XCTUnwrap(MobileFixtures.firstServer(in: container))
        let (controller, handles) = MobileFakeTerminal.controller(.idle)
        let flag = Flag()
        _ = MobileProbeWindow.make(size: CGSize(width: 390, height: 844), placement: .visibleOnScreen, isolateHost: true,
                                   rootView: ShellSwap(flag: flag, controller: controller))
        try await Task.sleep(for: .milliseconds(300))
        controller.start(profile: host, container: container, relay: HostKeyChallengeRelay())
        let connected = await MobileFakeTerminal.waitUntilConnected(controller)
        XCTAssertTrue(connected)
        let terminal = controller.terminal
        await waitUntilFed(terminal)
        let wide = await reported(terminal)

        let view = terminal.view
        XCTAssertEqual(view.frame.size, CGSize(width: 390, height: 500))
        terminal.feed(Data("保留的内容".utf8))
        let surface = try XCTUnwrap(view.surface)
        let oldContainer = view.superview

        flag.wide = false
        try await Task.sleep(for: .milliseconds(400))

        XCTAssertFalse(view.superview === oldContainer, "新容器接走了它")
        XCTAssertTrue(view.superview is MTerminalContainerView)
        XCTAssertTrue(view.surface === surface, "复用同一个视图、同一个 surface")
        XCTAssertTrue(surfaceText(terminal).contains("保留的内容"), "画面上的内容不丢")
        XCTAssertTrue(terminal.shadow.viewportText().contains("保留的内容"))
        assertCommitted(terminal, CGSize(width: 300, height: 400))
        XCTAssertEqual(controller.state, .connected)
        let narrow = await reported(terminal)
        XCTAssertNotEqual(narrow.grid, wide.grid)
        XCTAssertEqual(narrow.count, wide.count + 1, "外壳切换只让程序收到一次尺寸通知")
        let transport = try XCTUnwrap(handles.latest)
        let sent = await ledger(of: transport) {
            $0.lastCols.map(Int.init) == narrow.cols && $0.lastRows.map(Int.init) == narrow.rows
        }
        XCTAssertEqual(sent.lastCols.map(Int.init), narrow.cols)
        XCTAssertEqual(sent.lastRows.map(Int.init), narrow.rows)
        controller.close()
    }

    // MARK: - 重连

    /// 重连后新传输要补发当前尺寸：PTY 是新开的，不知道已经排成多少行列。
    func testRetryReplaysTheLatestSize() async throws {
        let container = try MobileFixtures.modelContainer(seed: .smoke)
        let host = try XCTUnwrap(MobileFixtures.firstServer(in: container))
        let (controller, handles) = MobileFakeTerminal.controller(
            MobileFakeTerminalScript(linesPerSecond: 0, seconds: 0, connectFailure: "第一次连不上"), .idle)
        controller.start(profile: host, container: container, relay: HostKeyChallengeRelay())
        let failed = await MobileFakeTerminal.waitUntil(timeout: .seconds(3)) {
            if case .failed = controller.state { return true }
            return false
        }
        XCTAssertTrue(failed)
        // 终端报来的网格都走这个入口（`GhosttyTerminalBridge.gridChanged`）。
        controller.terminal.input.reportSize(cols: 61, rows: 29)

        controller.restart()
        let connected = await MobileFakeTerminal.waitUntilConnected(controller)
        XCTAssertTrue(connected)

        XCTAssertEqual(handles.issuedCount, 2)
        let transport = try XCTUnwrap(handles.latest)
        let sent = await ledger(of: transport) { $0.lastCols == 61 && $0.lastRows == 29 }
        XCTAssertEqual(sent.lastCols, 61)
        XCTAssertEqual(sent.lastRows, 29)
        controller.close()
    }

    // MARK: - 键盘升降（真会话主体）

    /// 键盘升起又收起（换输入法、切应用时常见）：中途的高度不碰终端，PTY 也不收 SIGWINCH；
    /// 停住了才各提交一次，收回时回到原来的行数。
    func testKeyboardOnlyReflowsOnceItStopsMoving() async throws {
        defer { MobileProbeWindow.closeAll() }
        let container = try MobileFixtures.modelContainer(seed: .smoke)
        let host = try XCTUnwrap(MobileFixtures.firstServer(in: container))
        let (tab, handles) = MobileFakeTerminal.tab(host: host, .idle)
        let body = TerminalSessionBody(tab: tab, isActive: true, onClose: {}).environment(MobileStore()).modelContainer(container)
        let (window, hosting) = MobileProbeWindow.make(size: CGSize(width: 390, height: 800), placement: .visibleOnScreen,
                                                       isolateHost: true, rootView: body)
        hosting.safeAreaRegions = .all
        tab.controller.start(profile: host, container: container, relay: HostKeyChallengeRelay())
        let connected = await MobileFakeTerminal.waitUntilConnected(tab.controller)
        XCTAssertTrue(connected)
        let terminal = tab.controller.terminal
        await waitUntilFed(terminal)
        let open = await reported(terminal)
        let openHeight = terminal.view.frame.height
        let transport = try XCTUnwrap(handles.latest)
        let resizesBefore = await ledger(of: transport) { $0.lastRows.map(Int.init) == open.rows }.resizeCount

        func setKeyboard(_ height: CGFloat) {
            hosting.additionalSafeAreaInsets.bottom = height
            hosting.view.setNeedsLayout()
            window.layoutIfNeeded()
        }

        // 一来一回，没停住。
        setKeyboard(336)
        setKeyboard(0)
        try await Task.sleep(for: .milliseconds(300))
        let roundTrip = await reported(terminal)
        var resizes = await transport.ledger.resizeCount
        XCTAssertEqual(roundTrip, open, "没停住就不该重排")
        XCTAssertEqual(terminal.view.frame.height, openHeight)
        XCTAssertEqual(resizes, resizesBefore, "没停住就不该通知程序")

        // 升起并停住。
        setKeyboard(336)
        XCTAssertEqual(terminal.view.frame.height, openHeight, "停稳之前不重排")
        try await Task.sleep(for: .milliseconds(300))
        let shrunk = await reported(terminal)
        XCTAssertLessThan(terminal.view.frame.height, openHeight)
        XCTAssertLessThan(shrunk.rows, open.rows)
        XCTAssertEqual(shrunk.count, open.count + 1)
        let raised = await ledger(of: transport) { $0.resizeCount > resizesBefore }
        XCTAssertEqual(raised.resizeCount, resizesBefore + 1)
        XCTAssertEqual(raised.lastRows.map(Int.init), shrunk.rows)

        // 收起并停住。
        setKeyboard(0)
        try await Task.sleep(for: .milliseconds(300))
        let reopened = await reported(terminal)
        XCTAssertEqual(reopened.grid, open.grid)
        resizes = await ledger(of: transport) { $0.resizeCount > resizesBefore + 1 }.resizeCount
        XCTAssertEqual(resizes, resizesBefore + 2)
        tab.controller.close()
    }
}
