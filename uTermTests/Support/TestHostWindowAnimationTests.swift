import AppKit
import XCTest
@testable import uTerm

/// 测试宿主里收 / 摆窗口不起后台线程上的 AppKit 动画（`TestHostWindowAnimations`）。
///
/// 屏幕关着时每个这样的动画都把一条 GCD 全局队列的工作线程卡在 `-[NSAnimation _runBlocking]` 里，
/// 攒满 `kern.wq_max_constrained_threads`（90）之后投到全局并发队列的活全都排不上。见
/// `TestHostWindowAnimations` 的注释（uTable 2026-11-25 查清，uTerm 的探针夹具同源）。
@MainActor
final class TestHostWindowAnimationTests: XCTestCase {

    override func tearDown() {
        // 对照臂临时打开过，这里无论成败都关回去。
        TestHostWindowAnimations.disable()
        super.tearDown()
    }

    /// 摆一轮窗口再全部收掉：探针三档摆法（含读 Ghostty 画面用的浮层）、手写的带标题栏窗口、宿主自己的窗口。
    private func cycleWindows() async throws {
        let rect = NSRect(x: 0, y: 0, width: 320, height: 200)
        let windows: [NSWindow] = [
            ProbeWindow.make(contentRect: rect),
            ProbeWindow.make(contentRect: rect, placement: .transparentOnScreen),
            ProbeWindow.make(contentRect: rect, placement: .transparentOnScreen, keepsDrawing: true),
            ProbeWindow.make(contentRect: rect, styleMask: [.titled, .closable, .resizable],
                             key: true, placement: .transparentOnScreen),
            {
                let window = NSWindow(contentRect: rect, styleMask: [.titled, .resizable],
                                      backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.setFrameOrigin(ProbeWindow.offScreenOrigin)
                window.orderFront(nil)
                return window
            }(),
        ]
        try await Task.sleep(for: .milliseconds(100))
        ProbeWindow.isolateHostWindows(keeping: [])
        for window in windows { window.orderOut(nil) }
        // 动画（如果起了）0.25s，等它播完再换回原实现，免得留下半截。
        try await Task.sleep(for: .milliseconds(400))
    }

    func testOrderingWindowsInAndOutStartsNoThreadedAnimation() async throws {
        // 先量出厂状态：这条用例自己不碰开关，关没关全看测试包加载时的 `TestBundlePrincipal`。
        // 键不存在时 `bool(forKey:)` 也是 false，所以要读原值。
        XCTAssertEqual(UserDefaults.standard.object(forKey: TestHostWindowAnimations.defaultsKey) as? Bool, false,
                       "测试包加载时就该关掉窗口动画（TestBundlePrincipal）")
        let started = try await TestHostWindowAnimations.threadedAnimationsStarted(during: cycleWindows)
        XCTAssertEqual(started, [],
                       "收 / 摆窗口起了后台线程上的动画；屏幕关着时每个都会卡住一条全局队列线程")

        // 对照臂：打开动画时同一套动作确实会起 `.nonblockingThreaded` 的 NSAnimation——
        // 证明上面的「一个都没有」是因为关掉了，不是因为钩子没挂上。用户在全局域或启动
        // 参数里自己设过这个键时，注册域压不过它，对照臂就不跑。
        let defaults = UserDefaults.standard
        guard defaults.volatileDomain(forName: UserDefaults.argumentDomain)[TestHostWindowAnimations.defaultsKey] == nil,
              defaults.persistentDomain(forName: UserDefaults.globalDomain)?[TestHostWindowAnimations.defaultsKey] == nil
        else { return }
        defaults.register(defaults: [TestHostWindowAnimations.defaultsKey: true])
        let enabled = try await TestHostWindowAnimations.threadedAnimationsStarted(during: cycleWindows)
        TestHostWindowAnimations.disable()
        XCTAssertFalse(enabled.isEmpty, "对照臂：打开窗口动画时收窗口应当起线程动画，钩子没挂上？")
    }
}
