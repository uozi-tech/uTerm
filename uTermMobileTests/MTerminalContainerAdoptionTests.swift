import SwiftTerm
import SwiftUI
import UIKit
import XCTest
@testable import uTermMobile

/// 容器与外壳切换、收起、取消的边界（基础规则见 `MTerminalContainerViewTests`）。
@MainActor
final class MTerminalContainerAdoptionTests: XCTestCase {
    private final class Recorder: TerminalViewDelegate {
        var sizes: [[Int]] = []
        func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) { sizes.append([newCols, newRows]) }
        func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {}
        func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
        func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
        func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
        func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {}
    }

    private let mounted = CGSize(width: 400, height: 600)
    private let recorder = Recorder()

    private func hosted() async -> (MTerminalView, MTerminalContainerView) {
        let view = MTerminalView(frame: .zero, font: .monospacedSystemFont(ofSize: 11, weight: .regular))
        view.terminalDelegate = recorder
        let container = MTerminalContainerView(terminalView: view, fontSize: 11)
        lay(container, mounted)
        await settle()
        recorder.sizes = []
        return (view, container)
    }

    private func lay(_ container: MTerminalContainerView, _ size: CGSize) {
        container.frame = CGRect(origin: .zero, size: size)
        container.layoutIfNeeded()
    }

    private func settle() async {
        try? await Task.sleep(for: MTerminalContainerView.settleDelay * 3)
    }

    private func grid(_ view: SwiftTerm.TerminalView) -> [Int] {
        [view.getTerminal().cols, view.getTerminal().rows]
    }

    // MARK: - 外壳切换

    /// 新容器尺寸不同：等停稳后终端跟上新容器，程序只收到一次通知。
    func testAdoptingContainerOfADifferentSizeCommitsAfterSettling() async {
        let (view, stale) = await hosted()
        let before = grid(view)
        let live = MTerminalContainerView(terminalView: view, fontSize: 11)
        XCTAssertTrue(view.superview === live)

        lay(live, CGSize(width: 300, height: 500))
        XCTAssertEqual(grid(view), before, "已经排布过的终端也要等停稳")
        await settle()

        XCTAssertEqual(view.frame, CGRect(x: 0, y: 0, width: 300, height: 500))
        XCTAssertEqual(recorder.sizes, [grid(view)])
        lay(stale, .zero)
        XCTAssertEqual(view.frame.size, CGSize(width: 300, height: 500), "旧容器不再摆放它")
    }

    /// 新容器尺寸相同（转屏来回、外壳切换）：程序什么都不该收到。
    func testAdoptingContainerOfTheSameSizeDoesNotReflow() async {
        let (view, _) = await hosted()
        let live = MTerminalContainerView(terminalView: view, fontSize: 11)

        lay(live, mounted)
        await settle()

        XCTAssertEqual(view.frame.size, mounted)
        XCTAssertEqual(recorder.sizes, [])
    }

    /// 旧容器等待期间被换掉：它的提交不能落到已被接走的终端上。
    func testPendingCommitOfAReplacedContainerIsDropped() async {
        let (view, stale) = await hosted()
        lay(stale, CGSize(width: 200, height: 300))
        let live = MTerminalContainerView(terminalView: view, fontSize: 11)
        lay(live, mounted)

        await settle()

        XCTAssertEqual(view.frame.size, mounted)
        XCTAssertEqual(recorder.sizes, [])
    }

    // MARK: - 收起与取消

    func testContainerExposedAgainAtANewSizeCommits() async {
        let (view, container) = await hosted()
        lay(container, .zero)
        await settle()

        lay(container, CGSize(width: 300, height: 400))
        await settle()

        XCTAssertEqual(view.frame.size, CGSize(width: 300, height: 400))
        XCTAssertEqual(recorder.sizes, [grid(view)])
    }

    func testCancelledHoldNeverCommits() async {
        let (view, container) = await hosted()
        let before = grid(view)

        lay(container, CGSize(width: 200, height: 300))
        container.cancelHold()
        await settle()

        XCTAssertEqual(grid(view), before, "表示层拆掉之后不再动终端")
    }

    // MARK: - 等待期间的摆放

    /// 键盘升起又收起：贴底的偏移要还原，不能留下错位的终端。
    func testRoundTripRestoresPosition() async {
        let (view, container) = await hosted()

        lay(container, CGSize(width: 400, height: 300))
        XCTAssertEqual(view.frame.minY, -300)
        lay(container, mounted)

        XCTAssertEqual(view.frame, CGRect(origin: .zero, size: mounted))
    }

    /// 容器变高（键盘收起）的等待期间贴顶，下面留白而不是跑到中间。
    func testHeldTerminalStaysAtTopWhenShorterThanContainer() async {
        let (view, container) = await hosted()

        lay(container, CGSize(width: 400, height: 800))

        XCTAssertEqual(view.frame.minY, 0)
        XCTAssertEqual(view.frame.height, mounted.height)
    }

    // MARK: - 字号

    func testFontRoundTripDoesNotReflow() async {
        let (view, container) = await hosted()

        container.setFontSize(9)
        container.setFontSize(11)
        await settle()

        XCTAssertEqual(view.font.pointSize, 11, accuracy: 0.01)
        XCTAssertEqual(recorder.sizes, [])
    }

    func testFontAloneCommitsAfterSettling() async {
        let (view, container) = await hosted()

        container.setFontSize(14)
        XCTAssertEqual(view.font.pointSize, 11, accuracy: 0.01)
        await settle()

        XCTAssertEqual(view.font.pointSize, 14, accuracy: 0.01)
        XCTAssertEqual(recorder.sizes, [grid(view)])
    }

    // MARK: - SwiftUI 外壳切换全程

    @Observable final class Flag { var wide = true }

    private struct ShellSwap: View {
        let flag: Flag
        let controller: MobileTerminalController

        var body: some View {
            // 两个分支的结构身份不同：切换时 SwiftUI 拆掉旧表示层、新建一个，和外壳在标签栏 ⇄ 侧栏之间切换时一样。
            if flag.wide {
                HStack(spacing: 0) { SwiftTermView(controller: controller, autoFocus: false) }.frame(width: 390, height: 500)
            } else {
                VStack(spacing: 0) { SwiftTermView(controller: controller, autoFocus: false) }.frame(width: 300, height: 400)
            }
        }
    }

    /// 外壳重建：同一个终端视图、缓冲不丢、连接不断，尺寸跟新容器走，PTY 收到的是最终尺寸。
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
        try await Task.sleep(for: .milliseconds(200))

        let terminal = try XCTUnwrap(controller.terminalView)
        XCTAssertEqual(terminal.frame.size, CGSize(width: 390, height: 500))
        terminal.feed(text: "保留的内容")
        let oldContainer = terminal.superview

        flag.wide = false
        try await Task.sleep(for: .milliseconds(400))

        XCTAssertTrue(controller.terminalView === terminal, "复用同一个视图，缓冲区不丢")
        XCTAssertFalse(terminal.superview === oldContainer, "新容器接走了它")
        XCTAssertEqual(terminal.frame, CGRect(x: 0, y: 0, width: 300, height: 400))
        XCTAssertEqual(controller.state, .connected)
        let grid = grid(terminal)
        let ledger = await handles.latest!.ledger
        XCTAssertEqual(ledger.lastCols.map(Int.init), grid[0])
        XCTAssertEqual(ledger.lastRows.map(Int.init), grid[1])
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
        controller.resize(cols: 61, rows: 29)

        controller.restart()
        let connected = await MobileFakeTerminal.waitUntilConnected(controller)
        XCTAssertTrue(connected)
        _ = await MobileFakeTerminal.waitUntil(timeout: .milliseconds(300)) { false }

        XCTAssertEqual(handles.issuedCount, 2)
        let ledger = await handles.latest!.ledger
        XCTAssertEqual(ledger.lastCols, 61)
        XCTAssertEqual(ledger.lastRows, 29)
        controller.close()
    }

    // MARK: - 键盘升降（真会话主体）

    /// 键盘升起又收起（换输入法、切应用时常见）：中途的高度不碰缓冲区，PTY 也不收 SIGWINCH；
    /// 停住了才各提交一次，收回时回到原来的行数。
    func testKeyboardOnlyReflowsOnceItStopsMoving() async throws {
        defer { MobileProbeWindow.closeAll() }
        let container = try MobileFixtures.modelContainer(seed: .smoke)
        let host = try XCTUnwrap(MobileFixtures.firstServer(in: container))
        let (tab, handles) = MobileFakeTerminal.tab(host: host, .idle)
        let body = TerminalSessionBody(tab: tab, onClose: {}).environment(MobileStore()).modelContainer(container)
        let (window, hosting) = MobileProbeWindow.make(size: CGSize(width: 390, height: 800), placement: .visibleOnScreen,
                                                       isolateHost: true, rootView: body)
        hosting.safeAreaRegions = .all
        tab.controller.start(profile: host, container: container, relay: HostKeyChallengeRelay())
        let connected = await MobileFakeTerminal.waitUntilConnected(tab.controller)
        XCTAssertTrue(connected)
        try await Task.sleep(for: .milliseconds(500))
        let terminal = try XCTUnwrap(tab.controller.terminalView)
        let rows = terminal.getTerminal().rows
        let transport = try XCTUnwrap(handles.latest)
        let resizesBefore = await transport.ledger.resizeCount

        func setKeyboard(_ height: CGFloat) {
            hosting.additionalSafeAreaInsets.bottom = height
            hosting.view.setNeedsLayout()
            window.layoutIfNeeded()
        }

        // 一来一回，没停住。
        setKeyboard(336)
        setKeyboard(0)
        try await Task.sleep(for: .milliseconds(300))
        var resizes = await transport.ledger.resizeCount
        XCTAssertEqual(terminal.getTerminal().rows, rows)
        XCTAssertEqual(resizes, resizesBefore, "没停住就不该通知程序")

        // 升起并停住。
        setKeyboard(336)
        XCTAssertEqual(terminal.getTerminal().rows, rows, "停稳之前不重排")
        try await Task.sleep(for: .milliseconds(300))
        let shrunk = terminal.getTerminal().rows
        XCTAssertLessThan(shrunk, rows)
        resizes = await transport.ledger.resizeCount
        XCTAssertEqual(resizes, resizesBefore + 1)
        let reported = await transport.ledger.lastRows
        XCTAssertEqual(reported.map(Int.init), shrunk)

        // 收起并停住。
        setKeyboard(0)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(terminal.getTerminal().rows, rows)
        resizes = await transport.ledger.resizeCount
        XCTAssertEqual(resizes, resizesBefore + 2)
        tab.controller.close()
    }
}
