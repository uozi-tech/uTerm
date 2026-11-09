#if DEBUG
import GhosttyTerminal
import SwiftUI
import UIKit

// Ghostty 评估分支临时（测量门 M16：给人亲手比手感），只在 Debug 构建里有，不进 main。
// 设置 › 诊断 › 引擎试用 打开「Ghostty 试用」后，之后新开的终端标签由 `MobileTerminalController` 建一个
// `GhosttyTerminalBridge`（GhosttyKit 画、host-managed IO 接真实 SSH），`TerminalSessionBody` 换成下面这个视图。
// 没接的：程序状态（OSC 7501）、贴图、字号随宽度变（固定 11pt 等效）、日夜切换（按开标签那一刻的外观取配色）。

@MainActor
enum GhosttyTrial {
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: DefaultsKey.debugGhosttyTrial) }

    /// 整个 App 共用一个 ghostty app（每种外观一个）。
    private static var controllers: [Bool: GhosttyTerminal.TerminalController] = [:]

    static func makeBridge() -> GhosttyTerminalBridge {
        let dark = UIScreen.main.traitCollection.userInterfaceStyle != .light
        let controller = controllers[dark] ?? GhosttyTerminalBridge.makeController(
            dark: dark, fontSize: GhosttyTerminalBridge.ghosttyFontSize(points: 11))
        controllers[dark] = controller
        return GhosttyTerminalBridge(controller: controller)
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
