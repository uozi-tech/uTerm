import SwiftUI
import SwiftTerm
import UIKit

/// 把 SwiftTerm 的 iOS `TerminalView` 桥接进 SwiftUI。Coordinator 实现
/// `TerminalViewDelegate`，把键盘输入与尺寸变化转给 `MobileTerminalController`。
/// 配色随 app 外观（日 / 夜）自动取 VS Code Light / Dark（对齐 macOS `TerminalColorScheme`）。
struct SwiftTermView: UIViewRepresentable {
    let controller: MobileTerminalController
    var fontSize: CGFloat = 13
    /// 是否为当前激活视图（终端模式）。Agent 模式时终端被移出屏外，传 false → 主动 resign；
    /// 否则 SwiftTerm 的 TerminalView 会一直抢第一响应者，把终端键盘悬在 Agent 输入框上。
    var isActive: Bool = true
    /// 是否允许会话出现即自动弹键盘。连接中页期间传 false——否则键盘会盖住中转页、
    /// 并因软键盘安全区收缩把中转页内容顶上去（动画错乱）。中转页撤下后由终端屏重新聚焦。
    var autoFocus: Bool = true
    @Environment(\.colorScheme) private var colorScheme

    func makeUIView(context: Context) -> SwiftTerm.TerminalView {
        let font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let view = SwiftTerm.TerminalView(frame: .zero, font: font)
        view.terminalDelegate = context.coordinator
        // 去掉 SwiftTerm 自带的键盘附加栏（esc/ctrl/tab/F1/方向键……），它和我们自绘的
        // `TerminalKeyBar` 重复堆两层。置 nil 后键盘上方只留 `TerminalKeyBar` 一层。
        view.inputAccessoryView = nil
        view.minimumContrastRatio = MTerminalColors.minimumContrastRatio
        apply(MTerminalColors.resolve(dark: colorScheme == .dark), to: view)
        // 稳定块光标（对齐设计稿 / macOS：steady block，不闪烁）。
        view.feed(text: "\u{1B}[2 q")
        controller.attach(view)
        // 键盘始终展开：会话出现即聚焦，无需先点终端（仅激活态、且非连接中页期间）。
        if isActive, autoFocus { DispatchQueue.main.async { _ = view.becomeFirstResponder() } }
        return view
    }

    func updateUIView(_ uiView: SwiftTerm.TerminalView, context: Context) {
        // 外观切换（日 / 夜）时实时重应用配色。
        apply(MTerminalColors.resolve(dark: colorScheme == .dark), to: uiView)
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

    final class Coordinator: NSObject, TerminalViewDelegate {
        let controller: MobileTerminalController
        init(controller: MobileTerminalController) { self.controller = controller }

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
