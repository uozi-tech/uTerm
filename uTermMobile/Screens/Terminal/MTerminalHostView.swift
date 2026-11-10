import SwiftUI
import UIKit

extension EnvironmentValues {
    /// 正在连续改宽度（拖分隔条）：字号先不跟，松手再换。字号随宽度连续变化，跟着换等于每帧重排一次。
    @Entry var mTerminalHoldsFontSize = false
}

/// 把会话的终端视图（`MobileTerminalController.terminal.view`，GhosttyKit 画）挂进 SwiftUI。
/// 视图归控制器持有：横屏翻 size class 会令外壳在 Tab / Split 间切换、`TerminalScreen` 连带重建——复用同一个视图，
/// 屏幕内容与回滚都在，既不空白也不断连。这里只负责挂上、聚焦、可见性、字号与光标设置。
/// 配色随 App 外观（日 / 夜）由 GhosttyKit 按视图的 trait 自己切（两套都来自 `TerminalColorScheme`）。
struct MTerminalHostView: UIViewRepresentable {
    let controller: MobileTerminalController
    var fontSize: CGFloat = MGhosttyTerminalView.defaultFontSize
    /// 是否为当前激活视图（终端模式）。Agent 模式时终端被移出屏外，传 false → 主动 resign；
    /// 否则终端键盘会悬在 Agent 输入框上。
    var isActive: Bool = true
    /// 是否允许会话出现即自动弹键盘。连接中页期间传 false——否则键盘会盖住中转页、
    /// 并因软键盘安全区收缩把中转页内容顶上去（动画错乱）。中转页撤下后由终端屏重新聚焦。
    var autoFocus: Bool = true
    /// 这片终端在不在屏上（所在格的前台标签、终端模式）。不在屏上时不跟尺寸、不画，见 `MTerminalContainerView`。
    var isOnScreen: Bool = true
    /// 用户点了终端（分屏时据此切聚焦格）。SwiftUI 手势拿不到 UIKit 视图上的触摸，
    /// 所以挂一个不吞触摸的 UITapGestureRecognizer。
    var onInteract: (() -> Void)? = nil
    @Environment(\.mTerminalHoldsFontSize) private var holdsFontSize
    /// 光标形状 / 闪烁：与 Mac 同步的两个偏好（设置 › 终端里改，默认见 `TerminalCursorPreference`）。
    @AppStorage(DefaultsKey.terminalCursorShape)
    private var cursorShapeRaw: String = TerminalCursorPreference.defaultShape.rawValue
    @AppStorage(DefaultsKey.terminalCursorBlink)
    private var cursorBlink: Bool = TerminalCursorPreference.defaultBlink

    private var cursorLook: TerminalCursorLook {
        TerminalCursorLook(shape: TerminalCursorPreference.shape(rawValue: cursorShapeRaw), blink: cursorBlink)
    }

    func makeUIView(context: Context) -> MTerminalContainerView {
        let view = controller.terminal.view
        context.coordinator.onInteract = onInteract
        // 复用旧视图时先摘掉上一个表示层留下的识别器（它的 target 是已销毁的旧 coordinator）。
        view.gestureRecognizers?
            .filter { $0.name == Coordinator.interactGestureName }
            .forEach(view.removeGestureRecognizer)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.interacted))
        tap.name = Coordinator.interactGestureName
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)
        GhosttyTerminalBridge.applyCursorIfNeeded(cursorLook)
        // 键盘默认展开：会话出现即聚焦，无需先点终端（仅激活态、非连接中页期间、已连上、用户没收起——
        // 失败重试成功后失败页换回本视图时走这里）。
        if isActive, autoFocus { DispatchQueue.main.async { controller.focusKeyboard() } }
        return MTerminalContainerView(terminal: controller.terminal, fontSize: fontSize, isOnScreen: isOnScreen)
    }

    func updateUIView(_ container: MTerminalContainerView, context: Context) {
        context.coordinator.onInteract = onInteract
        // 设置里改了光标形状 / 闪烁（或从 Mac 同步过来）时重装；没变不装（装一次会盖掉程序自己设的光标）。
        GhosttyTerminalBridge.applyCursorIfNeeded(cursorLook)
        container.isOnScreen = isOnScreen
        // 字号随屏幕 / 视图宽度自适应：旋转、分屏时和新宽度一起提交，网格只重排一次。
        // 拖分隔条时等松手再换，否则停顿一下就要重排一次。
        if !holdsFontSize { container.setFontSize(fontSize) }
        // Agent 模式（isActive=false）：主动收键盘，否则终端键盘盖住 Agent 输入框。
        let view = container.terminalView
        if !isActive, view.isFirstResponder { _ = view.resignFirstResponder() }
    }

    static func dismantleUIView(_ container: MTerminalContainerView, coordinator: Coordinator) {
        container.cancelHold()
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
