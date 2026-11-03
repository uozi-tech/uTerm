import SwiftUI
import SwiftTerm
import UIKit

/// 只在自己的会话允许时才肯当第一响应者的终端视图。
/// 光在我们自己的聚焦调用里设卡不够：UIKit 收起抽屉 / 弹层时会把之前的第一响应者自动恢复回来，
/// 不经过任何我们的代码——第一个标签已连上、第二个标签正在建连时，键盘就是这样冒出来的。
final class MTerminalView: SwiftTerm.TerminalView {
    weak var controller: MobileTerminalController?

    override var canBecomeFirstResponder: Bool { controller?.canTakeKeyboard ?? false }
}

/// 把 SwiftTerm 的 iOS `TerminalView` 桥接进 SwiftUI。Coordinator 实现
/// `TerminalViewDelegate`，把键盘输入与尺寸变化转给 `MobileTerminalController`。
/// 配色随 app 外观（日 / 夜）自动取 VS Code Light / Dark（对齐 macOS `TerminalColorScheme`）。
struct SwiftTermView: UIViewRepresentable {
    let controller: MobileTerminalController
    var fontSize: CGFloat = 11
    /// 是否为当前激活视图（终端模式）。Agent 模式时终端被移出屏外，传 false → 主动 resign；
    /// 否则 SwiftTerm 的 TerminalView 会一直抢第一响应者，把终端键盘悬在 Agent 输入框上。
    var isActive: Bool = true
    /// 是否允许会话出现即自动弹键盘。连接中页期间传 false——否则键盘会盖住中转页、
    /// 并因软键盘安全区收缩把中转页内容顶上去（动画错乱）。中转页撤下后由终端屏重新聚焦。
    var autoFocus: Bool = true
    /// 用户点了终端（分屏时据此切聚焦格）。SwiftUI 手势拿不到 UIKit 视图上的触摸，
    /// 所以挂一个不吞触摸的 UITapGestureRecognizer。
    var onInteract: (() -> Void)? = nil
    @Environment(\.colorScheme) private var colorScheme

    func makeUIView(context: Context) -> SwiftTerm.TerminalView {
        // 复用控制器已持有的终端视图：横屏翻 size class 会令外壳在 Tab/Split 间切换、
        // TerminalScreen 连带重建——复用同一视图可保活 SwiftTerm 的屏幕缓冲与回滚，
        // 既不空白也不断连。仅首次创建新视图。
        let isFresh = controller.terminalView == nil
        let view = controller.terminalView ?? MTerminalView(
            frame: .zero, font: UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular))
        (view as? MTerminalView)?.controller = controller
        // 把（可能是新建的）coordinator 接上：复用旧视图时旧 coordinator 已随旧表示层销毁。
        view.terminalDelegate = context.coordinator
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
        // 终端强制英文 ASCII 键盘：避免跟随系统语言弹出中文等候选栏（命令输入应纯 ASCII）。
        // 联想 / 自动更正 / 智能标点已由 SwiftTerm 默认关闭（autocorrection 等均为 .no）。
        // 注：Agent（AI 模式）走独立的 SwiftUI 输入框，不受此限制。
        view.keyboardType = .asciiCapable
        // 去掉 SwiftTerm 自带的键盘附加栏（esc/ctrl/tab/F1/方向键……），它和我们自绘的
        // `TerminalKeyBar` 重复堆两层。置 nil 后键盘上方只留 `TerminalKeyBar` 一层。
        view.inputAccessoryView = nil
        view.minimumContrastRatio = MTerminalColors.minimumContrastRatio
        apply(MTerminalColors.resolve(dark: colorScheme == .dark), to: view)
        if isFresh {
            // 稳定块光标（对齐设计稿 / macOS：steady block，不闪烁），仅新建时设一次。
            view.feed(text: "\u{1B}[2 q")
        }
        controller.attach(view)
        // 键盘始终展开：会话出现即聚焦，无需先点终端（仅激活态、非连接中页期间、且已连上——
        // 失败重试成功后失败页换回本视图时走这里）。
        if isActive, autoFocus { DispatchQueue.main.async { controller.focusKeyboard() } }
        return view
    }

    func updateUIView(_ uiView: SwiftTerm.TerminalView, context: Context) {
        context.coordinator.onInteract = onInteract
        // 外观切换（日 / 夜）时实时重应用配色。
        apply(MTerminalColors.resolve(dark: colorScheme == .dark), to: uiView)
        // 字号随屏幕 / 视图宽度自适应：旋转、分屏、尺寸变化时实时换字（换字会触发
        // SwiftTerm 重排并回调 sizeChanged → resize PTY）。阈值过滤避免无意义重排。
        if abs(uiView.font.pointSize - fontSize) > 0.1 {
            uiView.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
        // Agent 模式（isActive=false）：主动收键盘，否则终端键盘盖住 Agent 输入框。
        if !isActive, uiView.isFirstResponder { _ = uiView.resignFirstResponder() }
    }

    /// 把一套配色装进 SwiftTerm 视图：ANSI 表 + 前景 / 背景 / 光标 / 选区。
    private func apply(_ s: MTerminalColors, to view: SwiftTerm.TerminalView) {
        view.installColors(s.ansi)
        view.nativeForegroundColor = s.foreground
        view.nativeBackgroundColor = s.background
        view.backgroundColor = s.background
        view.caretColor = s.cursor
        view.caretTextColor = s.background   // 块光标下的字符用底色，保证可读
        view.selectedTextBackgroundColor = s.selection
    }

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    final class Coordinator: NSObject, TerminalViewDelegate, UIGestureRecognizerDelegate {
        static let interactGestureName = "uterm.interact"
        let controller: MobileTerminalController
        var onInteract: (() -> Void)?
        init(controller: MobileTerminalController) { self.controller = controller }

        @objc func interacted() { onInteract?() }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            controller.write(Data(data))
        }
        func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
            controller.resize(cols: UInt16(clamping: newCols), rows: UInt16(clamping: newRows))
        }
        func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {
            if !title.isEmpty { controller.title = title }
        }
        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
        func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
        func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
        func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {
            if let url = URL(string: link) { UIApplication.shared.open(url) }
        }
    }
}
