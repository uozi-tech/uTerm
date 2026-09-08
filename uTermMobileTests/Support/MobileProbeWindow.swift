import SwiftUI
import UIKit

/// iOS 探针的建窗夹具 —— 对应桌面 `uTermTests/Support/ProbeWindow.swift`，
/// 但**不是**它的逐行移植：两个平台的「真窗口」含义差得远。
///
/// 桌面那份要解决的问题在 iOS 上都不存在或换了形态：
/// - **不用躲用户的鼠标**。桌面探针得把窗口做成 `alphaValue = 0` 的屏内窗、再断言
///   `blindsRealMouse`，否则真光标会点亮 `.onHover` 把读数染红。模拟器里没有会
///   飘进来的真光标，SwiftUI iOS 也没有 `.onHover` 这条路径。
/// - **不用留 terminationAnchor**。`uTermApp` 是纯 SwiftUI `WindowGroup`，最后一个
///   窗口一消失宿主进程就 `exit(0)`；`MobileApp` 走 `UIApplicationMain`，宿主
///   `UIWindow` 由系统 scene 持有，我们建的窗拆光也不会让进程没。
///
/// iOS 这边真正要小心的是另外两条，都写进了 `make(...)`：
/// 1. **窗口必须真的 `isHidden = false`**。离屏 / 隐藏的 `UIWindow` 不参与
///    渲染循环，`CADisplayLink` 照常回调，但 `UIScrollView` 的 cell 复用与
///    SwiftUI 的懒行实例化不会按可见区推进 —— 量到的是一棵没长开的树。
/// 2. **`makeKeyAndVisible()` 之后要让宿主自己的窗口靠后**。宿主 app 的启动画面 /
///    引导页在跑真实逻辑（SwiftData 容器、CloudKit 监听），盖在上面会污染读数。
///    做法是给探针窗口一个更高的 `windowLevel`，而不是把宿主窗口拆掉 —— 拆掉
///    会连带把 SwiftData 的 `ModelContainer` 环境一起带走。
@MainActor
enum MobileProbeWindow {

    /// 探针窗口的层级：`.normal + 100`。压在宿主窗口之上，又低于系统警告框。
    static let level = UIWindow.Level(UIWindow.Level.normal.rawValue + 100)

    /// 建一个上屏的 `UIWindow`，挂上 `UIHostingController(rootView:)`。
    ///
    /// - Parameters:
    ///   - size: 内容尺寸。传 `nil` 用当前 scene 的屏幕尺寸（真实档）。
    ///   - rootView: 被测视图。
    /// - Returns: 窗口 + 承载它的 hosting controller（hosting controller 的
    ///   `view` 才是量 `UIView` 数 / `hitTest` 的根）。
    static func make<V: View>(size: CGSize? = nil,
                              rootView: V) -> (window: UIWindow, host: UIHostingController<V>) {
        let scene = activeScene()
        let bounds: CGRect
        if let size {
            bounds = CGRect(origin: .zero, size: size)
        } else if let scene {
            bounds = scene.screen.bounds
        } else {
            bounds = CGRect(x: 0, y: 0, width: 390, height: 844)
        }

        let host = UIHostingController(rootView: rootView)
        host.view.frame = bounds
        // 关掉安全区插入：探针要的是「这么大一块内容有多贵」，不是「刘海占了多少」。
        // 不关的话不同模拟器（有无灵动岛）会给出不同的可视行数，档与档之间没法比。
        host.safeAreaRegions = []
        host.view.backgroundColor = .white

        let window: UIWindow
        if let scene {
            window = UIWindow(windowScene: scene)
            window.frame = bounds
        } else {
            window = UIWindow(frame: bounds)
        }
        window.windowLevel = level
        window.rootViewController = host
        window.isHidden = false
        window.makeKeyAndVisible()
        return (window, host)
    }

    /// 当前前台的 `UIWindowScene`。测试宿主启动后必然有一个；取不到时
    /// `make` 退回无 scene 的窗口（仍能布局，只是拿不到真实屏幕尺寸/刷新率）。
    static func activeScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

    /// 屏幕的最大刷新率（Hz）。心跳/单帧的「理想值」按它换算，
    /// 别写死 60 —— 模拟器跟着宿主 Mac 的显示器走，ProMotion 上是 120。
    static func maximumFramesPerSecond() -> Int {
        activeScene()?.screen.maximumFramesPerSecond ?? 60
    }

    /// 拆窗。`rootViewController = nil` 必须显式做：只置 `isHidden` 的话
    /// hosting controller 与它的图层后备存储会跟着窗口一起被 scene 拖着不放，
    /// 下一档的 footprint 读数就带着上一档的账。
    static func close(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
        window.windowScene = nil
    }

    /// 一句话描述窗口状态，出问题时贴进日志比猜快。
    static func describe(_ window: UIWindow) -> String {
        let scene = window.windowScene
        return "frame=\(window.frame) level=\(window.windowLevel.rawValue) "
            + "hidden=\(window.isHidden) key=\(window.isKeyWindow) "
            + "scene=\(scene == nil ? "nil" : String(describing: scene!.activationState)) "
            + "maxFPS=\(maximumFramesPerSecond())"
    }
}

/// `CADisplayLink` 拍数计数器。
///
/// 桌面探针用「8ms `Task.sleep` 循环收到几拍」当心跳；iOS 有真正的
/// `CADisplayLink`，直接数系统实际交付了几帧，比 sleep 循环更贴近体感。
/// 两者都留：`Task.sleep` 拍数量的是「主线程还愿不愿意回来」，
/// `CADisplayLink` 拍数量的是「渲染循环还在不在跑」。
@MainActor
final class DisplayLinkCounter {
    private var link: CADisplayLink?
    private(set) var ticks = 0
    /// 每两拍之间的间隔（ms）。p95 高 = 掉帧。
    private(set) var intervals: [Double] = []
    private var last: CFTimeInterval = 0
    /// 每拍回调里跑一次的活儿（例如推进滚动位置）。
    var onTick: (() -> Void)?

    func start() {
        ticks = 0
        intervals.removeAll()
        last = 0
        let link = CADisplayLink(target: self, selector: #selector(tick))
        // `.common` 而非默认 mode：测试里主 runloop 会进 tracking/modal 模式，
        // 默认 mode 的 link 在那期间静默停摆，拍数直接腰斩，看起来像卡顿。
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        if last > 0 { intervals.append((link.timestamp - last) * 1000) }
        last = link.timestamp
        ticks += 1
        onTick?()
    }
}
