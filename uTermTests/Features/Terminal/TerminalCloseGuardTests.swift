import AppKit
import XCTest
@testable import uTerm

/// 关标签的二次确认：真 `TerminalSession` + 假后端 + 真 NSAlert sheet。
@MainActor
final class TerminalCloseGuardTests: XCTestCase {
    private var window: NSWindow!

    override func setUp() async throws {
        window = ProbeWindow.make(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320))
        window.isReleasedWhenClosed = false
    }

    override func tearDown() async throws {
        window?.close()
        window = nil
    }

    private func connectedSession(reporting activity: TerminalActivity) async -> TerminalSession {
        let backend = MockBackend()
        await backend.setForegroundActivity(activity)
        let session = TerminalSession()
        await session.connect(using: backend)
        return session
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition())
    }

    private func button(_ title: String, in sheet: NSWindow?) throws -> NSButton {
        func find(_ view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.title == title { return button }
            return view.subviews.lazy.compactMap(find).first
        }
        return try XCTUnwrap(sheet?.contentView.flatMap(find), "找不到按钮「\(title)」")
    }

    private func text(in view: NSView) -> [String] {
        ((view as? NSTextField).map { [$0.stringValue] } ?? []) + view.subviews.flatMap(text(in:))
    }

    func testIdleTabClosesWithoutAsking() async throws {
        let session = await connectedSession(reporting: .idle)
        var closed = false
        TerminalCloseGuard.requestClose(session, window: window) { closed = true }
        try await waitUntil { closed }
        XCTAssertNil(window.attachedSheet)
    }

    func testDisconnectedTabClosesWithoutProbing() async throws {
        var closed = false
        TerminalCloseGuard.requestClose(TerminalSession(), window: window) { closed = true }
        try await waitUntil { closed }
        XCTAssertNil(window.attachedSheet)
    }

    func testEmptyGroupClosesImmediately() {
        var closed = false
        TerminalCloseGuard.requestClose(nil, window: window) { closed = true }
        XCTAssertTrue(closed)
    }

    func testBusyTabAsksAndCancelKeepsIt() async throws {
        let session = await connectedSession(reporting: .running("npm"))
        var closed = false
        TerminalCloseGuard.requestClose(session, window: window) { closed = true }
        try await waitUntil { self.window.attachedSheet != nil }
        let sheet = window.attachedSheet
        XCTAssertTrue(try XCTUnwrap(sheet?.contentView.map(text(in:))).contains("「npm」还在运行"))

        try button("取消", in: sheet).performClick(nil)
        try await waitUntil { self.window.attachedSheet == nil }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(closed)
    }

    func testBusyTabClosesAfterConfirming() async throws {
        let session = await connectedSession(reporting: .running(nil))
        var closed = false
        TerminalCloseGuard.requestClose(session, window: window) { closed = true }
        try await waitUntil { self.window.attachedSheet != nil }
        try button("关闭标签页", in: window.attachedSheet).performClick(nil)
        try await waitUntil { closed }
    }

    func testUnknownStillAsks() async throws {
        let session = await connectedSession(reporting: .unknown)
        var closed = false
        TerminalCloseGuard.requestClose(session, window: window) { closed = true }
        try await waitUntil { self.window.attachedSheet != nil }
        try button("取消", in: window.attachedSheet).performClick(nil)
        try await waitUntil { self.window.attachedSheet == nil }
        XCTAssertFalse(closed)
    }

    /// 探测和确认期间再按一次关闭，不能叠第二个对话框，也不能关两次。
    func testRepeatedRequestsDoNotStack() async throws {
        let session = await connectedSession(reporting: .running("vim"))
        var closeCount = 0
        TerminalCloseGuard.requestClose(session, window: window) { closeCount += 1 }
        TerminalCloseGuard.requestClose(session, window: window) { closeCount += 1 }
        try await waitUntil { self.window.attachedSheet != nil }
        TerminalCloseGuard.requestClose(session, window: window) { closeCount += 1 }
        try button("关闭标签页", in: window.attachedSheet).performClick(nil)
        try await waitUntil { closeCount > 0 }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(closeCount, 1)
    }

    func testCanAskAgainAfterCancelling() async throws {
        let session = await connectedSession(reporting: .running("vim"))
        TerminalCloseGuard.requestClose(session, window: window) {}
        try await waitUntil { self.window.attachedSheet != nil }
        try button("取消", in: window.attachedSheet).performClick(nil)
        try await waitUntil { self.window.attachedSheet == nil }
        try await Task.sleep(for: .milliseconds(50))

        TerminalCloseGuard.requestClose(session, window: window) {}
        try await waitUntil { self.window.attachedSheet != nil }
        try button("取消", in: window.attachedSheet).performClick(nil)
        try await waitUntil { self.window.attachedSheet == nil }
    }

    /// 工作区入口：空闲标签真的被摘下；等确认期间不动标签。
    func testWorkspaceClosesIdleTabThroughTheGuard() async throws {
        let workspace = WorkspaceModel()
        workspace.openServer(profileID: UUID(), title: "A")
        workspace.openServer(profileID: UUID(), title: "B")
        let tabs = workspace.terminalGroups.allTabs
        XCTAssertEqual(tabs.count, 2)
        workspace.requestCloseTerminalTab(tabs[0].id)
        try await waitUntil { workspace.terminalGroups.allTabs.count == 1 }
        XCTAssertEqual(workspace.terminalGroups.allTabs.first?.id, tabs[1].id)
    }

    // MARK: - 关窗（红灯、⌘W 关最后一个标签都走 performClose）

    /// 能真关的窗口：带关闭按钮，装好代理。
    private func closableWindow(sessions: [TerminalSession]) -> (NSWindow, WindowCloseProxy) {
        let closable = ProbeWindow.make(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
                                        styleMask: [.titled, .closable])
        closable.isReleasedWhenClosed = false
        let proxy = WindowCloseProxy.installed(on: closable)
        proxy.terminalSessions = { sessions }
        return (closable, proxy)
    }

    func testRedButtonClosesIdleWindowWithoutAsking() async throws {
        let session = await connectedSession(reporting: .idle)
        let (closable, proxy) = closableWindow(sessions: [session])
        closable.performClose(nil)
        try await waitUntil { !closable.isVisible }
        XCTAssertNil(closable.attachedSheet)
        withExtendedLifetime(proxy) {}
    }

    func testRedButtonAsksWhenATabIsBusyAndCancelKeepsTheWindow() async throws {
        let idle = await connectedSession(reporting: .idle)
        let busy = await connectedSession(reporting: .running("npm"))
        let (closable, proxy) = closableWindow(sessions: [idle, busy])
        closable.performClose(nil)
        try await waitUntil { closable.attachedSheet != nil }
        let sheet = closable.attachedSheet
        XCTAssertTrue(try XCTUnwrap(sheet?.contentView.map(text(in:))).contains("「npm」还在运行"))

        try button("取消", in: sheet).performClick(nil)
        try await waitUntil { closable.attachedSheet == nil }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(closable.isVisible)

        // 取消之后还能再问一次，这次关掉。只弹一次框，不会被重走的 performClose 再拦一遍。
        closable.performClose(nil)
        try await waitUntil { closable.attachedSheet != nil }
        try button("关闭窗口", in: closable.attachedSheet).performClick(nil)
        try await waitUntil { !closable.isVisible }
        withExtendedLifetime(proxy) {}
        closable.close()
    }

    func testRepeatedRedButtonClicksDoNotStackDialogs() async throws {
        let busy = await connectedSession(reporting: .running("vim"))
        let (closable, proxy) = closableWindow(sessions: [busy])
        closable.performClose(nil)
        closable.performClose(nil)
        try await waitUntil { closable.attachedSheet != nil }
        closable.performClose(nil)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(closable.sheets.count, 1)
        try button("取消", in: closable.attachedSheet).performClick(nil)
        try await waitUntil { closable.attachedSheet == nil }
        withExtendedLifetime(proxy) {}
        closable.close()
    }

    func testProxyIsSharedByInstallers() {
        let (closable, proxy) = closableWindow(sessions: [])
        XCTAssertTrue(WindowCloseProxy.installed(on: closable) === proxy)
        closable.close()
    }
}
