import UDesignKit
// uTerm/Views/WelcomeToolbar.swift
import SwiftUI
import AppKit

/// Welcome 顶部 toolbar：左搜索框（设计稿 boxed 输入 + ⌘K 芯片）+ 右「密钥」/「本机终端」/「新建」按钮。
///
/// 几何对齐设计稿 `Toolbar`（分区方案 v3）：高 48、左 12 / 右 8 内边距、子项间距 10；
/// 坐在窗口画布上，无底色、无底部分隔线。
/// 搜索框直接复用 DesignKit 的 `UDSearchField`（带描边底框与 ⌘K 提示），不再裸放
/// 放大镜 + 纯文本输入。
struct WelcomeToolbar: View {
    @Environment(\.openWindow) private var openWindow
    @Binding var query: String
    let onNewLocalShell: () -> Void
    let onNewServer: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            UDSearchField(text: $query)
            UDButton(title: String(localized: "密钥", comment: "工具栏按钮：打开密钥管理"), style: .secondary, systemImage: "key") {
                openWindow(id: "keys")
            }
            UDButton(title: String(localized: "本机终端"), style: .secondary, systemImage: "terminal", action: onNewLocalShell)
                .help("新建本机终端（⇧⌘N）")
            UDButton(title: String(localized: "新建", comment: "工具栏按钮：新建主机"), style: .primary, systemImage: "plus", action: onNewServer)
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        // 紧贴 38pt 标题栏：32pt 控件只在下方留 8pt 到分隔线。原先 48 高上下各 8，
        // 与同为卡面色的标题栏叠在一起显得间隔过大（实机反馈）。
        .padding(.bottom, 8)
        .frame(height: 40)
    }
}

// MARK: - 阻止开屏自动聚焦

/// 阻止宿主窗口在出现时把键盘焦点自动交给第一个文本框（欢迎页搜索框）。
///
/// macOS 在窗口成为 key 时会自动选中第一个可成为第一响应者的文本框，导致搜索框
/// 「开屏即高亮聚焦」。此修饰器在窗口初次挂载时把 `initialFirstResponder` 抢占给一个
/// 零尺寸占位视图，使 AppKit 根本不会去聚焦搜索框那个文本框——搜索框只在用户主动
/// 点按时才聚焦（⌘K 现在打开命令面板，不再聚焦搜索框）。仅初次生效，之后不再干预
/// （不会抢走用户后续主动选中的焦点）。
///
/// 之所以「抢占」而非「先聚焦再退掉」：一旦文本框成为第一响应者，AppKit 会安装窗口共享
/// 的字段编辑器（`NSTextView`）；之后用 `makeFirstResponder(nil)` 退掉它会拆除
/// `NSTextInputContext`，该过程在主线程（user-interactive QoS）上同步等待更低 QoS 的
/// 文本输入服务，触发 Thread Performance Checker 的优先级反转「Hang Risk」告警。从源头
/// 不让它聚焦，就没有这次拆除、也就没有告警，同时省掉脆弱的 0.1s 延迟兜底。
private struct DisableInitialAutoFocus: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ResignView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    /// 零尺寸、可成为第一响应者但不接收任何文本输入的占位视图。窗口初次挂载时抢占
    /// `initialFirstResponder`，把初次焦点引到自己身上，AppKit 便不会自动聚焦搜索框。
    private final class ResignView: NSView {
        private var didClaim = false

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !didClaim else { return }
            didClaim = true
            // 指向自己，而不是留空：留空（nil）等于让 AppKit 自动挑第一个文本框。
            window.initialFirstResponder = self
            // 若窗口已是 key，initialFirstResponder 不会再被读取，这里直接抢占；仅当
            // 当前还没有有意义的焦点（首响应者仍是窗口自身）时才抢，避免误伤已聚焦项。
            if window.firstResponder === window {
                window.makeFirstResponder(self)
            }
        }
    }
}

extension View {
    /// 阻止窗口开屏时自动聚焦第一个文本框（见 `DisableInitialAutoFocus`）。
    func disablesInitialAutoFocus() -> some View {
        background(DisableInitialAutoFocus().frame(width: 0, height: 0).allowsHitTesting(false))
    }
}
