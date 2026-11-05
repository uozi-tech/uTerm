import SwiftUI
import SwiftTerm
import UIKit
import XCTest
@testable import uTermMobile

/// 点分屏按钮时终端经历了几轮尺寸变化。逐帧记录，变化时打印一行。
@MainActor
final class SplitResizeProbeTests: XCTestCase {
    /// App 不在前台时不布局、不弹键盘，读数全是假的（真机息屏或被切走时就这样），必须判失败而不是空跑通过。
    private func requireForeground() async throws {
        for _ in 0..<150 where UIApplication.shared.applicationState != .active {
            try await Task.sleep(for: .milliseconds(100))
        }
        let scene = try XCTUnwrap(MobileProbeWindow.activeScene())
        print("PROBE state app=\(UIApplication.shared.applicationState.rawValue) scene=\(scene.activationState.rawValue) screen=\(scene.screen.bounds.size) coord=\(scene.coordinateSpace.bounds.size)")
        XCTAssertEqual(UIApplication.shared.applicationState, .active, "App 不在前台，探针读数无效")
        try XCTSkipUnless(UIApplication.shared.applicationState == .active)
    }

    func testSplitTimeline() async throws {
        try await requireForeground()
        defer { MobileProbeWindow.closeAll() }
        let c = try MobileFixtures.modelContainer(seed: .smoke)
        let h = try XCTUnwrap(MobileFixtures.firstServer(in: c))
        let relay = HostKeyChallengeRelay()
        let store = MobileStore()
        store.showWorkspace = true
        let (work, _) = MobileFakeTerminal.sessions(count: 1, hosts: [h],
            script: MobileFakeTerminalScript(linesPerSecond: 200, seconds: 1, corpus: .ansiColor),
            container: c, relay: relay)
        let term = try XCTUnwrap(work.terminalTabs.first)
        let root = WorkspaceScreen().environment(store).environment(relay).environment(work)
            .environment(\.mAccent, M.accent).modelContainer(c)
        _ = MobileProbeWindow.make(placement: .visibleOnScreen, isolateHost: true, rootView: root)
        _ = await MobileFakeTerminal.waitUntilConnected(term.controller)
        try await Task.sleep(for: .seconds(4))
        let view = try XCTUnwrap(term.controller.terminalView)
        term.controller.ownsKeyboard = true
        term.controller.focusKeyboard()
        try await Task.sleep(for: .seconds(2))
        print("SPLITPROBE ready first=\(view.isFirstResponder) kbOwner=\(term.controller.ownsKeyboard)")

        let t0 = CACurrentMediaTime()
        var last = ""
        var sizes: [String] = []
        var changes = 0
        func sample() {
            let t = view.getTerminal()
            let p = view.layer.presentation()?.frame ?? .zero
            let gridNow = "\(t.cols)x\(t.rows)"
            if sizes.last != gridNow { sizes.append(gridNow) }
            let line = "grid=\(gridNow) font=\(String(format: "%.2f", view.font.pointSize)) bounds=\(Int(view.bounds.width))x\(Int(view.bounds.height)) offY=\(Int(view.contentOffset.y)) pres=\(Int(p.width))x\(Int(p.height))@\(Int(p.minX)),\(Int(p.minY)) kb=\(view.isFirstResponder)"
            if line != last {
                last = line
                changes += 1
                print("SPLITPROBE +\(Int((CACurrentMediaTime() - t0) * 1000))ms \(line)")
            }
        }
        sample()
        XCTAssertGreaterThan(view.bounds.width, 0, "终端没有布局，读数无效")
        print("SPLITPROBE tap-split")
        work.split()
        let end = CACurrentMediaTime() + 2.5
        while CACurrentMediaTime() < end {
            sample()
            try await Task.sleep(for: .milliseconds(8))
        }
        print("SPLITPROBE grids=\(sizes) changes=\(changes)")
        // 宽度 + 字号最多两轮（键盘收起再加一轮）；回到逐帧缩放时这里是十几次。
        XCTAssertLessThanOrEqual(sizes.count, 4, "\(sizes)")
        term.controller.close()
    }

    /// 换输入法（键盘高度变化）时，终端底部有没有被键盘盖住。不用 MobileProbeWindow：它关了安全区。
    func testKeyboardHeightTimeline() async throws {
        try await requireForeground()
        let c = try MobileFixtures.modelContainer(seed: .smoke)
        let h = try XCTUnwrap(MobileFixtures.firstServer(in: c))
        let relay = HostKeyChallengeRelay()
        let store = MobileStore()
        store.showWorkspace = true
        let (work, _) = MobileFakeTerminal.sessions(count: 1, hosts: [h],
            script: MobileFakeTerminalScript(linesPerSecond: 200, seconds: 1, corpus: .ansiColor),
            container: c, relay: relay)
        let term = try XCTUnwrap(work.terminalTabs.first)
        let host = UIHostingController(rootView: WorkspaceScreen().environment(store).environment(relay).environment(work)
            .environment(\.mAccent, M.accent).modelContainer(c))
        let win = UIWindow(windowScene: try XCTUnwrap(MobileProbeWindow.activeScene()))
        win.windowLevel = .alert + 1
        win.rootViewController = host
        win.makeKeyAndVisible()
        defer { win.isHidden = true }
        _ = await MobileFakeTerminal.waitUntilConnected(term.controller)
        try await Task.sleep(for: .seconds(2))
        let view = try XCTUnwrap(term.controller.terminalView)
        // 通知闭包是 @Sendable，不能直接改捕获的 var；交给主 actor 上的盒子（队列就是 .main）。
        let kbBox = KeyboardFrameBox()
        var kb: CGRect { kbBox.rect }
        let obs = NotificationCenter.default.addObserver(forName: UIResponder.keyboardDidChangeFrameNotification, object: nil, queue: .main) { n in
            let rect = (n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect) ?? .zero
            MainActor.assumeIsolated { kbBox.rect = rect }
        }
        defer { NotificationCenter.default.removeObserver(obs) }
        term.controller.ownsKeyboard = true
        term.controller.focusKeyboard()
        func report(_ tag: String) {
            let f = view.convert(view.bounds, to: nil)
            let t = view.getTerminal()
            let cell = view.bounds.height / max(CGFloat(t.rows), 1)
            let lastRowBottom = f.minY + CGFloat(t.rows) * floor(cell)
            print("KBPROBE \(tag): mode=\(view.textInputMode?.primaryLanguage ?? "nil") first=\(view.isFirstResponder) kb=\(Int(kb.minY))..\(Int(kb.maxY)) h=\(Int(kb.height)) term=\(Int(f.minY))..\(Int(f.maxY)) rows=\(t.rows) overlap=\(Int(f.maxY - kb.minY)) lastRowBottom=\(Int(lastRowBottom)) offY=\(Int(view.contentOffset.y)) yDisp=\(t.buffer.yDisp) cursorRow=\(t.getCursorLocation().y)/\(t.rows) contentH=\(Int(view.contentSize.height)) boundsH=\(Int(view.bounds.height)) keyW=\(Int(win.bounds.width))x\(Int(win.bounds.height)) safeB=\(Int(host.view.safeAreaInsets.bottom)) cellH=\(String(format: "%.1f", cell))")
        }
        /// 等 `seconds` 秒，逐帧记下网格变了几次。
        func watchGrid(_ seconds: Double) async throws -> [String] {
            var grids: [String] = []
            let end = CACurrentMediaTime() + seconds
            while CACurrentMediaTime() < end {
                let t = view.getTerminal()
                let g = "\(t.cols)x\(t.rows)"
                if grids.last != g { grids.append(g) }
                try await Task.sleep(for: .milliseconds(8))
            }
            return grids
        }
        try await Task.sleep(for: .seconds(2))
        report("en")
        let cls: AnyObject? = NSClassFromString("UIKeyboardInputModeController")
        let shared = try XCTUnwrap(cls?.perform(NSSelectorFromString("sharedInputModeController"))?.takeUnretainedValue())
        for mode in UITextInputMode.activeInputModes where mode.primaryLanguage != "en-US" {
            shared.setValue(mode, forKey: "currentInputMode")
            print("KBPROBE grids-on-switch=\(try await watchGrid(2))")
            report("switched-\(mode.primaryLanguage ?? "nil")")
            view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
            try await Task.sleep(for: .seconds(1))
            report("composing")
            view.unmarkText()
            try await Task.sleep(for: .seconds(1))
        }
        _ = view.resignFirstResponder()
        print("KBPROBE grids-on-hide=\(try await watchGrid(1.5))")
        term.controller.focusKeyboard()
        print("KBPROBE grids-on-show=\(try await watchGrid(1.5))")
        report("before-split")
        work.split()
        print("KBPROBE grids-on-split=\(try await watchGrid(2))")
        term.controller.close()
    }
}

/// 键盘探针记下的最近一次键盘帧（通知回调在主队列上写、探针在主 actor 上读）。
@MainActor
private final class KeyboardFrameBox {
    var rect = CGRect.zero
}
