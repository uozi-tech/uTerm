import XCTest
import SwiftTerm
import SwiftUI
import UPaneGroups
@testable import uTerm

@MainActor
@Observable
private final class FocusTestTabs {
    var active: TerminalSession
    init(active: TerminalSession) { self.active = active }
}

private struct FocusTestHost: View {
    let tabs: FocusTestTabs
    let gate: ActivePaneGate

    var body: some View {
        RemoteControlledTerminal(session: tabs.active)
            .id(ObjectIdentifier(tabs.active))
            .environment(\.activePaneGate, gate)
            .frame(width: 400, height: 300)
    }
}

@MainActor
final class TerminalContainerViewTests: XCTestCase {

    /// SwiftUI can defer a `TerminalHostView`'s `dismantleNSView` until *after*
    /// the next host view has already re-adopted the shared terminal view
    /// (tab switch away-and-back). The stale container must not rip the live
    /// terminal view out of the new container — doing so orphans the view and
    /// the pane renders black.
    func testStaleContainerDetachDoesNotStealTerminalFromNewContainer() {
        let terminalView = CopyableTerminalView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 300))

        let staleContainer = TerminalContainerView(terminalView: terminalView)
        XCTAssertTrue(terminalView.superview === staleContainer)

        // The new container re-adopts the same shared terminal view.
        let liveContainer = TerminalContainerView(terminalView: terminalView)
        XCTAssertTrue(terminalView.superview === liveContainer)

        // The stale container's deferred dismantle runs now.
        staleContainer.detachTerminal()

        // The terminal view must still belong to the live container.
        XCTAssertTrue(terminalView.superview === liveContainer)
    }

    /// When the terminal view is still parented to this container, detaching
    /// must unparent it as before.
    func testDetachUnparentsTerminalStillOwnedByThisContainer() {
        let terminalView = CopyableTerminalView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let container = TerminalContainerView(terminalView: terminalView)
        XCTAssertTrue(terminalView.superview === container)

        container.detachTerminal()

        XCTAssertNil(terminalView.superview)
    }

    // MARK: - 活动面板取得键盘焦点

    private func focusWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    private func mount(_ terminal: CopyableTerminalView, in window: NSWindow,
                       active: Bool) -> TerminalContainerView {
        let container = TerminalContainerView(terminalView: terminal)
        container.isActive = active
        window.contentView?.addSubview(container)
        return container
    }

    /// 切标签：新标签的终端挂上来就接收键盘，旧标签的终端交出焦点。
    func testActiveTerminalTakesFocusFromPreviousTerminalOnMount() async {
        let window = focusWindow()
        let previous = CopyableTerminalView(frame: .zero)
        _ = mount(previous, in: window, active: true)
        await Task.yield()
        XCTAssertTrue(window.firstResponder === previous)

        let next = CopyableTerminalView(frame: .zero)
        _ = mount(next, in: window, active: true)
        await Task.yield()

        XCTAssertTrue(window.firstResponder === next)
    }

    /// 分屏：后台组的终端挂载不拿焦点，变成活动组时才拿。
    func testInactiveTerminalTakesFocusOnlyWhenBecomingActive() async {
        let window = focusWindow()
        let terminal = CopyableTerminalView(frame: .zero)
        let container = mount(terminal, in: window, active: false)
        await Task.yield()
        XCTAssertFalse(window.firstResponder === terminal)

        container.isActive = true
        await Task.yield()

        XCTAssertTrue(window.firstResponder === terminal)
    }

    /// 连接晚完成才挂载的终端不能打断用户正在输入的内容。
    func testMountingTerminalDoesNotStealFocusFromTextInput() async {
        let window = focusWindow()
        let input = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        window.contentView?.addSubview(input)
        XCTAssertTrue(window.makeFirstResponder(input))

        _ = mount(CopyableTerminalView(frame: .zero), in: window, active: true)
        await Task.yield()

        XCTAssertTrue(window.firstResponder === input)
    }

    /// 走真实的 SwiftUI 挂载路径：本机终端窗口按 `.id` 换标签，工作区按活动门切活动组。
    func testSwiftUITabSwitchAndGateFlipMoveFocus() async throws {
        let first = TerminalSession()
        let second = TerminalSession()
        let tabs = FocusTestTabs(active: first)
        let gate = ActivePaneGate(isActive: true)
        let window = focusWindow()
        window.contentView = NSHostingView(rootView: FocusTestHost(tabs: tabs, gate: gate))

        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(window.firstResponder === first.terminalView)

        tabs.active = second
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(window.firstResponder === second.terminalView)

        gate.isActive = false
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(window.makeFirstResponder(nil))

        gate.isActive = true
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(window.firstResponder === second.terminalView)
    }

    // MARK: - 尺寸停稳才提交

    private let mounted = NSSize(width: 816, height: 606)

    private func hostedSession() async -> (TerminalSession, MockBackend, TerminalContainerView) {
        let session = TerminalSession()
        let backend = MockBackend()
        await session.connect(using: backend)
        let container = TerminalContainerView(terminalView: session.terminalView)
        lay(container, mounted)
        await settle()
        return (session, backend, container)
    }

    private func lay(_ container: TerminalContainerView, _ size: NSSize) {
        container.setFrameSize(size)
        container.layout()
    }

    private func settle() async {
        try? await Task.sleep(for: TerminalContainerView.settleDelay * 3)
    }

    private func grid(_ session: TerminalSession) -> [Int] {
        let terminal = session.terminalView.getTerminal()
        return [terminal.cols, terminal.rows]
    }

    private func forwarded(_ backend: MockBackend) async -> [[Int]] {
        await backend.resizes.map { [Int($0.cols), Int($0.rows)] }
    }

    func testFirstLayoutCommitsImmediately() async {
        let session = TerminalSession()
        let container = TerminalContainerView(terminalView: session.terminalView)
        let placeholder = grid(session)

        lay(container, mounted)

        XCTAssertNotEqual(grid(session), placeholder)
        session.dispose()
    }

    /// 回归点：尺寸变过去又变回来，缓冲区不能被碰。否则程序不知情、屏幕一直错位。
    func testRoundTripLeavesBufferAndBackendUntouched() async {
        let (session, backend, container) = await hostedSession()
        // 全屏程序的一帧，光标在屏幕下方：这种屏幕缩矮再拉高后内容会整体上移。
        let terminal = session.terminalView.getTerminal()
        let rows = (1...terminal.rows).map { "\u{1b}[\($0);1Hrow \($0)" }.joined()
        session.terminalView.feed(text: "\u{1b}[?1049h" + rows)
        let before = terminal.snapshotFingerprint(historyLines: 100)
        let forwardedBefore = await forwarded(backend)

        lay(container, NSSize(width: 816, height: 300))
        lay(container, mounted)
        await settle()

        XCTAssertEqual(terminal.snapshotFingerprint(historyLines: 100).differences(from: before), [:])
        let forwardedAfter = await forwarded(backend)
        XCTAssertEqual(forwardedAfter, forwardedBefore)
        session.dispose()
    }

    /// 缓冲区等到停稳才重排，程序随即收到通知；连续拖动只算一次。
    func testDragCommitsOnceAfterSettling() async {
        let (session, backend, container) = await hostedSession()
        let before = grid(session)
        let forwardedBefore = await forwarded(backend)

        for width in stride(from: 780, through: 500, by: -40) {
            lay(container, NSSize(width: CGFloat(width), height: 606))
            XCTAssertEqual(grid(session), before, "停稳之前不能重排")
        }
        await settle()

        let after = grid(session)
        XCTAssertLessThan(after[0], before[0])
        let forwardedAfter = await forwarded(backend)
        XCTAssertEqual(forwardedAfter, forwardedBefore + [after])
        session.dispose()
    }

    func testCollapsedPaneKeepsGrid() async {
        let (session, backend, container) = await hostedSession()
        let before = grid(session)
        let forwardedBefore = await forwarded(backend)

        lay(container, .zero)
        await settle()

        XCTAssertEqual(grid(session), before)
        let forwardedAfter = await forwarded(backend)
        XCTAssertEqual(forwardedAfter, forwardedBefore)
        session.dispose()
    }

    func testStaleContainerLayoutDoesNotResizeAdoptedTerminal() async {
        let (session, _, stale) = await hostedSession()
        let live = TerminalContainerView(terminalView: session.terminalView)
        lay(live, mounted)
        let before = grid(session)

        lay(stale, NSSize(width: 300, height: 200))
        await settle()

        XCTAssertEqual(grid(session), before)
        session.dispose()
    }
}
