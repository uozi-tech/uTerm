import AppKit
import XCTest
@testable import uTerm

/// 关窗时终端确认和未上传文件确认的先后。终端确认是真 NSAlert sheet；文件那一问原本是 `runModal`，
/// 单测里换成脚本。
@MainActor
final class WindowCloseProxyCombinedTests: XCTestCase {
    private var windows: [NSWindow] = []
    private var proxies: [WindowCloseProxy] = []
    /// 依次回答文件确认，答完之后一律放行（文件都传完了）。
    private var fileAnswers: [ExternalEditCloseGuard.Decision] = []
    private var fileAsks = 0
    private var uploads = 0
    private var uploadSucceeds = true

    override func tearDown() async throws {
        for window in windows { window.close() }
        windows = []
        proxies = []
        fileAnswers = []
        fileAsks = 0
        uploads = 0
        uploadSucceeds = true
    }

    private func makeWindow(sessions: [TerminalSession]) -> NSWindow {
        let window = ProbeWindow.make(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
                                      styleMask: [.titled, .closable])
        window.isReleasedWhenClosed = false
        let proxy = WindowCloseProxy.installed(on: window)
        proxy.terminalSessions = { sessions }
        proxy.askAboutUnsyncedFiles = { [unowned self] _ in
            fileAsks += 1
            return fileAnswers.isEmpty ? .proceed : fileAnswers.removeFirst()
        }
        proxy.uploadUnsyncedFiles = { [unowned self] _ in
            uploads += 1
            return uploadSucceeds
        }
        windows.append(window)
        proxies.append(proxy)
        return window
    }

    private func session(reporting activity: TerminalActivity) async -> TerminalSession {
        let backend = MockBackend()
        await backend.setForegroundActivity(activity)
        let session = TerminalSession()
        await session.connect(using: backend)
        return session
    }

    private func waitUntil(_ condition: @MainActor () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<300 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    private func click(_ title: String, in window: NSWindow,
                       file: StaticString = #filePath, line: UInt = #line) throws {
        func find(_ view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.title == title { return button }
            return view.subviews.lazy.compactMap(find).first
        }
        let button = try XCTUnwrap(window.attachedSheet?.contentView.flatMap(find),
                                   "找不到按钮「\(title)」", file: file, line: line)
        button.performClick(nil)
    }

    /// 让窗口有机会把异步的下一步走完，用来断言「什么都没发生」。
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(120))
    }

    func testTerminalIsAskedBeforeFilesAndConfirmingBothCloses() async throws {
        let window = makeWindow(sessions: [await session(reporting: .running("npm"))])

        window.performClose(nil)
        try await waitUntil { window.attachedSheet != nil }
        XCTAssertEqual(fileAsks, 0, "终端还没答复，不该问文件")

        try click("关闭窗口", in: window)
        try await waitUntil { !window.isVisible }
        XCTAssertEqual(fileAsks, 1)
    }

    func testCancellingTerminalNeverAsksAboutFiles() async throws {
        let window = makeWindow(sessions: [await session(reporting: .running("npm"))])

        window.performClose(nil)
        try await waitUntil { window.attachedSheet != nil }
        try click("取消", in: window)
        try await waitUntil { window.attachedSheet == nil }
        try await settle()

        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(fileAsks, 0)
    }

    func testCancellingFilesKeepsWindowAndNextCloseAsksTerminalAgain() async throws {
        fileAnswers = [.cancel]
        let window = makeWindow(sessions: [await session(reporting: .running("npm"))])

        window.performClose(nil)
        try await waitUntil { window.attachedSheet != nil }
        try click("关闭窗口", in: window)
        try await waitUntil { self.fileAsks == 1 }
        try await settle()
        XCTAssertTrue(window.isVisible, "文件那一问取消了，窗口要留着")
        XCTAssertNil(window.attachedSheet)

        // 上一次同意只管上一次：程序状态可能已经变了。
        window.performClose(nil)
        try await waitUntil { window.attachedSheet != nil }
        try click("关闭窗口", in: window)
        try await waitUntil { !window.isVisible }
        XCTAssertEqual(fileAsks, 2)
    }

    func testUploadSuccessClosesWithoutAskingTerminalTwice() async throws {
        fileAnswers = [.uploadThenProceed]
        let window = makeWindow(sessions: [await session(reporting: .running("npm"))])

        window.performClose(nil)
        try await waitUntil { window.attachedSheet != nil }
        try click("关闭窗口", in: window)

        // 上传后重走 performClose：不能再弹终端确认，否则用户要答两遍。
        try await waitUntil { !window.isVisible }
        XCTAssertEqual(uploads, 1)
        XCTAssertEqual(fileAsks, 2, "重走时再查一遍文件，那时已经传完")
    }

    func testUploadFailureKeepsWindowAndCanBeRetried() async throws {
        fileAnswers = [.uploadThenProceed]
        uploadSucceeds = false
        let window = makeWindow(sessions: [await session(reporting: .running("npm"))])

        window.performClose(nil)
        try await waitUntil { window.attachedSheet != nil }
        try click("关闭窗口", in: window)
        try await waitUntil { self.uploads == 1 }
        try await settle()
        XCTAssertTrue(window.isVisible)

        window.performClose(nil)
        try await waitUntil { window.attachedSheet != nil }
        try click("关闭窗口", in: window)
        try await waitUntil { !window.isVisible }
    }

    func testIdleTerminalGoesStraightToFiles() async throws {
        fileAnswers = [.cancel]
        let window = makeWindow(sessions: [await session(reporting: .idle)])

        window.performClose(nil)
        try await waitUntil { self.fileAsks == 1 }
        try await settle()
        XCTAssertNil(window.attachedSheet)
        XCTAssertTrue(window.isVisible)
    }

    func testWindowWithoutTerminalsAsksFilesSynchronously() {
        fileAnswers = [.cancel]
        let window = makeWindow(sessions: [])
        window.performClose(nil)
        XCTAssertEqual(fileAsks, 1)
        XCTAssertTrue(window.isVisible)
    }

    // MARK: - 原 delegate

    private final class ClosingDelegate: NSObject, NSWindowDelegate {
        var allowsClosing = true
        var askedToClose = 0
        var willClose = 0
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            askedToClose += 1
            return allowsClosing
        }
        func windowWillClose(_ notification: Notification) { willClose += 1 }
    }

    /// SwiftUI 的窗口 delegate 管着场景生命周期：两道确认都过了还要问它，其余消息照常转发。
    func testOriginalDelegateHasTheLastWordAndStillGetsOtherMessages() async throws {
        let delegate = ClosingDelegate()
        delegate.allowsClosing = false
        let window = ProbeWindow.make(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
                                      styleMask: [.titled, .closable])
        window.isReleasedWhenClosed = false
        window.delegate = delegate
        windows.append(window)
        let proxy = WindowCloseProxy.installed(on: window)
        proxies.append(proxy)
        let session = await session(reporting: .running("npm"))
        proxy.terminalSessions = { [session] }
        proxy.askAboutUnsyncedFiles = { _ in .proceed }

        window.performClose(nil)
        try await waitUntil { window.attachedSheet != nil }
        XCTAssertEqual(delegate.askedToClose, 0)
        try click("关闭窗口", in: window)
        try await waitUntil { delegate.askedToClose == 1 }
        XCTAssertTrue(window.isVisible)

        delegate.allowsClosing = true
        window.performClose(nil)
        try await waitUntil { window.attachedSheet != nil }
        try click("关闭窗口", in: window)
        try await waitUntil { !window.isVisible }
        XCTAssertEqual(delegate.willClose, 1)
    }

    // MARK: - 已经有对话框

    /// 窗口上已有一个 sheet 时再关标签：确认框排在它后面，不叠在一起；取消后标签还在。
    func testCloseConfirmationQueuesBehindAnExistingSheet() async throws {
        let window = makeWindow(sessions: [])
        let existing = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                                styleMask: [.titled], backing: .buffered, defer: false)
        existing.isReleasedWhenClosed = false
        window.beginSheet(existing, completionHandler: nil)
        try await waitUntil { window.attachedSheet === existing }

        var closed = false
        let busy = await session(reporting: .running("vim"))
        TerminalCloseGuard.requestClose(busy, window: window) { closed = true }
        try await settle()
        XCTAssertTrue(window.attachedSheet === existing, "不能抢掉用户正在看的对话框")
        XCTAssertFalse(closed)

        window.endSheet(existing)
        try await waitUntil { window.attachedSheet != nil && window.attachedSheet !== existing }
        try click("取消", in: window)
        try await waitUntil { window.attachedSheet == nil }
        try await settle()
        XCTAssertFalse(closed)
    }
}
