import AppKit
import ObjectiveC
import XCTest

/// 测试宿主里**关掉 AppKit 的窗口进出场动画**（移植自 uTable 的同名文件，2026-11-25）。
///
/// ## 为什么
///
/// `orderOut` / `orderFront` 一个窗口时，AppKit 默认（`animationBehavior = .default`）
/// 会起一个 `_NSWindowTransformAnimation`（0.25s，`.nonblockingThreaded`）：它被
/// `dispatch_async` 到 `com.apple.root.user-interactive-qos` 上，在那条 GCD 工作线程
/// 里 `-[NSAnimation _runBlocking]` 跑 runloop，等屏幕的 display link 一拍一拍推进。
///
/// **屏幕关着（显示器睡眠 / 锁屏）时 display link 不来，这条线程就一直卡着，直到屏幕亮起。**
/// 全量测试里探针（`ProbeWindow`、`GhosttySurfaceRig`、界面画廊）开关几百个窗口，
/// 「若干分钟后关闭显示器」一到，之后每收一个窗口就卡住一条线程。uTable 同一台机器、
/// 未改动的 main 上实测：显示器关掉后卡住的线程 2 → 91，停在 91 直到屏幕亮起才归零。
///
/// 停在 91 不是巧合：`sysctl kern.wq_max_constrained_threads` = 90。非 overcommit 的
/// 全局并发队列（`DispatchQueue.global(qos:)`）一共只有这么多线程，卡满之后，进程里
/// **任何**投到全局并发队列的活都排不上（私有串行队列与 Swift 协作线程池不受影响）。
/// 哪条用例正好依赖全局队列（NIO / SSH 的回调、Vision、`Process`、各种「回调在全局队列上」
/// 的系统 API），哪条就挂到屏幕亮起为止。
///
/// 这不是产品代码的问题：真用户极少在屏幕关着时开关窗口，而且屏幕一亮动画就播完、
/// 线程就还回去；只有「无人值守、连续开关几百个窗口」的测试宿主会被它攒满。
///
/// ## 怎么关
///
/// `NSAutomaticWindowAnimationsEnabled = NO` 写进**注册域**（`register(defaults:)`，
/// 只在本进程内存里，不落盘——测试宿主和正式版同一个 bundle id，写 app 域会改到用户
/// 的偏好）。AppKit 每次排窗口时现读它，测试包加载后再注册也来得及。
///
/// 装在测试包的 principal class 上（`INFOPLIST_KEY_NSPrincipalClass`），XCTest 加载
/// 测试包时、跑任何一条用例之前就生效，不依赖哪条用例先跑。
///
/// 只关窗口进出场的那段过渡，不碰显示节拍：Ghostty 的 surface 照样按 display link 出帧，
/// 读画面的探针（`GhosttySurfaceRig`、`UICatalogSnapshotTests`）不受影响。
@objc(UTermTestBundlePrincipal)
final class TestBundlePrincipal: NSObject {
    override init() {
        super.init()
        TestHostWindowAnimations.disable()
    }
}

enum TestHostWindowAnimations {
    static let defaultsKey = "NSAutomaticWindowAnimationsEnabled"

    /// 幂等：注册域重复注册同一个值没有副作用。
    static func disable() {
        UserDefaults.standard.register(defaults: [defaultsKey: false])
    }

    /// 在 `body` 执行期间，记下进程里起的每一个 `.nonblockingThreaded` 的 `NSAnimation`
    /// （类名）。只给回归用例用：临时换掉 `-[NSAnimation startAnimation]` 的实现，
    /// 结束后原样换回去。
    @MainActor
    static func threadedAnimationsStarted(during body: @MainActor () async throws -> Void) async rethrows -> [String] {
        let selector = NSSelectorFromString("startAnimation")
        guard let method = class_getInstanceMethod(NSAnimation.self, selector) else { return [] }
        typealias Start = @convention(c) (AnyObject, Selector) -> Void
        let original = method_getImplementation(method)
        let callOriginal = unsafeBitCast(original, to: Start.self)
        let recorder = Recorder()
        let hook: @convention(block) (AnyObject) -> Void = { animation in
            if let animation = animation as? NSAnimation,
               animation.animationBlockingMode == .nonblockingThreaded {
                recorder.append(String(describing: type(of: animation)))
            }
            callOriginal(animation, selector)
        }
        let replacement = imp_implementationWithBlock(hook)
        method_setImplementation(method, replacement)
        defer {
            method_setImplementation(method, original)
            imp_removeBlock(replacement)
        }
        try await body()
        return recorder.names
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        func append(_ name: String) { lock.withLock { storage.append(name) } }
        var names: [String] { lock.withLock { storage } }
    }
}
