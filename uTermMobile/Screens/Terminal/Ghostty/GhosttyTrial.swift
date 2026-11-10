#if DEBUG
import GhosttyTerminal
import SwiftUI
import UIKit

// Ghostty 评估分支临时（测量门 M16：给人亲手比手感），只在 Debug 构建里有，不进 main。
// 设置 › 诊断 › 引擎试用 打开「Ghostty 试用」后，之后新开的终端标签由 `MobileTerminalController` 建一个
// `GhosttyTerminalBridge`（GhosttyKit 画、host-managed IO 接真实 SSH），`TerminalSessionBody` 换成下面这个视图。
// 没接的：程序状态（OSC 7501）、贴图、字号随宽度变（固定 11pt 等效）。

@MainActor
enum GhosttyTrial {
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: DefaultsKey.debugGhosttyTrial) }

    /// 整个 App 共用一个 ghostty app；深 / 浅两套配色都在里面，随视图的日夜自己切。
    private static let controller = GhosttyTerminalBridge.makeController(
        fontSize: GhosttyTerminalBridge.ghosttyFontSize(points: 11))

    static func makeBridge() -> GhosttyTerminalBridge {
        applyRendererMode()
        // 给 xctrace 的 signpost（M16 第八轮，按「上玻璃」打分）：惯性每拍和每次换画面各一条。
        UTermScrollTrace.emitsSignposts = true
        // 排查滚动手感时设 `defaults write com.uozi.uTerm debug.ghosttyInputLog -bool YES`（或 Xcode 里改）：打开 GhosttyKit 的
        // 输入日志（含本地补丁的 uterm-scroll 行），打到 stdout，`devicectl device process launch --console` 抓。平时关着，
        // 每个滚动事件在主线程上打一行也有开销。
        if UserDefaults.standard.bool(forKey: DefaultsKey.debugGhosttyInputLog) {
            TerminalDebugLog.categories = [.input]
            TerminalDebugLog.isEnabled = true
        }
        return GhosttyTerminalBridge(controller: controller)
    }

    /// M16 第七轮：user 说第六轮（引擎 wakeup 不再在主线程同步重画）滚动时变糊。测试里两种行为的画面都不撕裂、不混合、
    /// 边缘一样锐，找不出差别，所以默认先回到第五轮的行为，留一个开关让 user 在同一台手机上来回比（全局生效，下一次 wakeup 起）。
    /// M16 第十轮：单指滚动默认交给 UIScrollView（手势、减速、回弹都是系统的），另一个开关切回第九轮的自写物理（下一次按下起）。
    /// 两个开关独立，四种组合都能跑。
    static func applyRendererMode() {
        UTermScrollTrace.legacyWakeupSyncDraw = !UserDefaults.standard.bool(forKey: DefaultsKey.debugGhosttyFreeRenderer)
        UTermScrollTrace.usesSystemScrolling = !UserDefaults.standard.bool(forKey: DefaultsKey.debugGhosttyOwnScrollPhysics)
    }
}

/// 试用时替代 `SwiftTermView`：视图归控制器持有（外壳切换时复用，回滚不丢），这里只负责挂上、聚焦、可见性。
struct GhosttyTrialTerminalView: UIViewRepresentable {
    let bridge: GhosttyTerminalBridge
    let controller: MobileTerminalController
    var isActive: Bool
    var autoFocus: Bool
    var isOnScreen: Bool
    var onInteract: (() -> Void)?

    func makeUIView(context: Context) -> MGhosttyTerminalView {
        let view = bridge.view
        view.removeFromSuperview()
        view.gestureRecognizers?
            .filter { $0.name == Coordinator.interactGestureName }
            .forEach(view.removeGestureRecognizer)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.interacted))
        tap.name = Coordinator.interactGestureName
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)
        context.coordinator.onInteract = onInteract
        if isActive, autoFocus { DispatchQueue.main.async { controller.focusKeyboard() } }
        return view
    }

    func updateUIView(_ view: MGhosttyTerminalView, context: Context) {
        context.coordinator.onInteract = onInteract
        view.setSurfaceVisible(isOnScreen)
        if !isActive, view.isFirstResponder { _ = view.resignFirstResponder() }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        static let interactGestureName = "uterm.interact"
        var onInteract: (() -> Void)?
        @objc func interacted() { onInteract?() }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}
#endif
