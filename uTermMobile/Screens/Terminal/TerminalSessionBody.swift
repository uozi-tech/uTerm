import UDesignKit
import SwiftUI
import SwiftData
import Observation

/// 终端连接页内容两态：纯终端 ⇄ Agent 自然语言（对齐 macOS 终端窗口的 `TerminalWindowContentMode`）。
enum MTerminalMode: Hashable { case terminal, agent }

/// 一个终端会话标签：一台主机 + 独立 `MobileTerminalController`（独立 SSH 会话）+
/// 该会话专属的 `AssistantModel`（复用 macOS Agent 状态机：流式 Markdown + `run_command`
/// 工具调用 + 审批 / 工具循环，跨「终端 / Agent」切换保活）。
/// 引用类型：放进 `@State` 数组里，跨标签切换时会话与回滚缓冲都保活。
/// `@Observable` —— `mode` 切换驱动标签栏开关与会话主体重渲染。
@MainActor
@Observable
final class TermTab: Identifiable {
    let id = UUID()
    let host: ServerProfile
    let controller: MobileTerminalController
    let agent = AssistantModel()
    /// Agent 在途驱动 Task 集：会话关闭时取消，停掉在途 LLM 流 / 工具循环（见 `MAgentTaskBag`）。
    let agentTasks = MAgentTaskBag()
    /// 当前是纯终端还是 Agent 模式。
    var mode: MTerminalMode = .terminal
    /// `transportFactory` 默认真 SSH——生产侧一律用 `TermTab(host:)`，行为不变；
    /// 探针注入假传输，从而在不发起任何真实连接的前提下把整屏挂起来。
    init(host: ServerProfile, transportFactory: MobileTerminalTransportFactory = .live) {
        self.host = host
        self.controller = MobileTerminalController(transportFactory: transportFactory)
    }
}

// MARK: - 单个会话主体：终端 + 键盘条，或失败态

struct TerminalSessionBody: View {
    let tab: TermTab
    /// 该会话是否在屏上（所在分屏格的前台标签）。不在屏上的会话降低终端刷新节拍，
    /// Agent 也只在屏上时于 .auto 档自动批准命令。
    var isActive: Bool = false
    /// 是否为聚焦格的前台（键盘归它）。分屏时两格的终端都在屏上，只有这一个自动弹键盘。
    var isFocused: Bool = true
    /// 用户点了这片终端（分屏时据此把焦点切到它所在的格）。
    var onInteract: (() -> Void)? = nil
    var onClose: () -> Void
    @Environment(MobileStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme
    private var terminalBg: Color { MTerminalColors.background(dark: colorScheme == .dark) }
    private var serverContext: String { "\(tab.host.name)（\(tab.host.displayEndpoint)）" }

    var body: some View {
        ZStack {
            // Agent 层（底）：始终挂载，保活对话 / 草稿 / 滚动位置。
            // isActive 仅在「激活标签 + Agent 模式」时为真——后台标签不在 .auto 档自动执行命令。
            MobileAgentChat(model: tab.agent, host: tab.host, tasks: tab.agentTasks,
                            isActive: isActive && tab.mode == .agent, serverContext: serverContext)
                .opacity(tab.mode == .agent ? 1 : 0)
                .allowsHitTesting(tab.mode == .agent)
            // 终端层（顶）：SwiftTerm 是 UIViewRepresentable，其 UIView 会无视 ZStack 顺序盖在
            // 上层 SwiftUI（Agent）之上，且 `.opacity(0)` 不一定作用于该 UIView——只用透明度切会
            // 出现「Agent 模式仍显示终端、切不过去」。故终端层放最上，Agent 模式时把它**移出屏外**
            //（仍挂载，保活会话与回滚缓冲，不卸载），把画面让给下面的 Agent 层。
            terminalLayer
                .allowsHitTesting(tab.mode == .terminal)
                .offset(x: tab.mode == .terminal ? 0 : -100_000)
        }
        // 终端与 Agent 两态同一个工作面（终端底色 == M.surface），切换时底色不跳。
        .background(tab.mode == .terminal ? terminalBg : M.surface)
        // 非活动 / Agent 模式的会话把终端 feed 节拍降下来（字节照常进缓冲，不丢）。
        // 所有会话常驻挂载，不降频的话切走的终端仍在按 60Hz 解析 + 重绘。
        .onAppear { syncForeground() }
        .onChange(of: isActive) { _, _ in syncForeground() }
        .onChange(of: tab.mode) { _, _ in syncForeground() }
    }

    /// 只有「当前激活标签 + 终端模式」的那一片算前台。
    /// 刻意不接 `onDisappear`：外壳在 Tab/Split 间切换时 `TerminalScreen` 会重建，
    /// 旧片的 `onDisappear` 可能晚于新片的 `onAppear` 到，置 false 会把会话卡在后台档。
    private func syncForeground() {
        tab.controller.isForeground = isActive && tab.mode == .terminal
    }

    private var terminalLayer: some View {
        Group {
            if case .failed(let msg) = tab.controller.state {
                failedView(msg)
            } else {
                VStack(spacing: 0) {
                    // 连接中页期间不自动弹键盘（autoFocus=false）；中转页撤下后由终端屏重新聚焦。
                    // 字号随可用宽度自适应（窄屏更小、宽屏 / iPad / 分屏更大）。
                    GeometryReader { geo in
                        SwiftTermView(controller: tab.controller,
                                      fontSize: adaptiveFontSize(width: geo.size.width),
                                      isActive: tab.mode == .terminal,
                                      autoFocus: store.connecting == nil && isFocused,
                                      onInteract: onInteract)
                    }
                    // 终端页边距（对齐 macOS `TerminalContainerView` 的 8pt 左右边）：字符不再贴着屏幕
                    // 边 / 圆角；上下各留 4pt，与上面标签条、下面键盘条的 hairline 拉开一行气口。
                    // 外层不 ignoresSafeArea，横屏刘海 / iPhone Duo 侧边灵动岛仍由安全区让开，
                    // 底色（同 M.surface）则铺满安全区。
                    .padding(.horizontal, Self.terminalInset.horizontal)
                    .padding(.vertical, Self.terminalInset.vertical)
                    .background(terminalBg)
                    TerminalKeyBar(controller: tab.controller)
                }
            }
        }
    }

    /// 终端文本区与四周的间距（pt）。
    static let terminalInset = (horizontal: CGFloat(8), vertical: CGFloat(4))

    /// 终端字号随可用宽度自适应。以 iPhone 14/15 竖屏逻辑宽度 390pt 为参考点，对应 11pt 基准：
    /// - 比它窄（SE、iPhone Duo 分屏 ≈ 330pt）：按比例缩小，最小 9pt，换出更多列；
    /// - 比它宽（Duo、横屏、iPad）：字只缓慢变大（每宽 250pt 约 +1pt），最大 13pt，多出来的宽度
    ///   都换成列数。原先按宽度等比放大到 16pt，Duo 展开 669pt 直接顶到 16pt，字大、列数反而
    ///   和窄屏差不多（实机反馈「Duo 上字号这么大」）。
    nonisolated static func adaptiveFontSize(width: CGFloat) -> CGFloat {
        guard width > 0 else { return 11 }
        let reference: CGFloat = 390, base: CGFloat = 11
        if width <= reference { return max(base * width / reference, 9) }
        return min(base + (width - reference) / 250, 13)
    }

    private func adaptiveFontSize(width: CGFloat) -> CGFloat {
        Self.adaptiveFontSize(width: width)
    }

    private func failedView(_ msg: String) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                MIcon(name: "warn", size: 38, color: M.danger, weight: .light)
                    .frame(width: 80, height: 80)
                    .background(M.danger.opacity(0.10)).clipShape(Circle())
                Text("连接失败 · \(tab.host.name)").font(M.sans(18, weight: .semibold)).foregroundStyle(M.text)
                Text(msg)
                    .font(M.sans(14)).foregroundStyle(M.text2)
                    .multilineTextAlignment(.center).lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: 340)
                HStack(spacing: 10) {
                    MBtn(title: "复制错误", icon: "copy", kind: .secondary, height: 44) {
                        UIPasteboard.general.string = msg
                    }.fixedSize()
                    MBtn(title: "关闭", kind: .tinted, height: 44, action: onClose).fixedSize()
                }
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 56).padding(.horizontal, 28).padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(M.surface)
    }
}

// MARK: - 终端快捷键条（设计稿键盘附加栏）

struct TerminalKeyBar: View {
    let controller: MobileTerminalController
    @Environment(\.mAccent) private var accent
    /// 是否展开多行面板（默认收起为单行；最左 ∧/∨ 切换）。
    @State private var expanded: Bool

    /// `expanded` 的初值。生产侧一律省略（收起），探针用它把展开档也挂起来量——
    /// `@State` 建出来之后外部改不了，不给初值就没法对照「收起 → 展开」的挂载账。
    init(controller: MobileTerminalController, expanded: Bool = false) {
        self.controller = controller
        _expanded = State(initialValue: expanded)
    }

    /// 一个快捷键：`label` 显示文本、`send` 发送给终端的字节序列。
    private struct TermKey: Identifiable {
        let label: String
        let send: String
        var id: String { label }
    }

    // 紧凑行常驻的高频键（横向滚动）。
    private let quickKeys: [TermKey] = [
        .init(label: "esc", send: "\u{1b}"), .init(label: "tab", send: "\t"),
        .init(label: "←", send: "\u{1b}[D"), .init(label: "↑", send: "\u{1b}[A"),
        .init(label: "↓", send: "\u{1b}[B"), .init(label: "→", send: "\u{1b}[C"),
        .init(label: "⌃C", send: "\u{03}"), .init(label: "/", send: "/"),
        .init(label: "|", send: "|"), .init(label: "~", send: "~"), .init(label: "-", send: "-"),
    ]
    // 展开面板：导航键（home/end 用 xterm 普通光标态序列）。
    private let navKeys: [TermKey] = [
        .init(label: "home", send: "\u{1b}[H"), .init(label: "end", send: "\u{1b}[F"),
        .init(label: "pgUp", send: "\u{1b}[5~"), .init(label: "pgDn", send: "\u{1b}[6~"),
        .init(label: "del", send: "\u{1b}[3~"), .init(label: "ins", send: "\u{1b}[2~"),
    ]
    // 展开面板：常用 Ctrl 组合。
    private let ctrlKeys: [TermKey] = [
        .init(label: "^A", send: "\u{01}"), .init(label: "^C", send: "\u{03}"),
        .init(label: "^D", send: "\u{04}"), .init(label: "^E", send: "\u{05}"),
        .init(label: "^K", send: "\u{0b}"), .init(label: "^L", send: "\u{0c}"),
        .init(label: "^R", send: "\u{12}"), .init(label: "^U", send: "\u{15}"),
        .init(label: "^W", send: "\u{17}"), .init(label: "^Z", send: "\u{1a}"),
    ]
    // 展开面板：功能键（F1–F4 用 SS3，F5–F12 用 CSI ~ 序列，对齐 xterm）。
    private let fnKeys: [TermKey] = [
        .init(label: "F1", send: "\u{1b}OP"), .init(label: "F2", send: "\u{1b}OQ"),
        .init(label: "F3", send: "\u{1b}OR"), .init(label: "F4", send: "\u{1b}OS"),
        .init(label: "F5", send: "\u{1b}[15~"), .init(label: "F6", send: "\u{1b}[17~"),
        .init(label: "F7", send: "\u{1b}[18~"), .init(label: "F8", send: "\u{1b}[19~"),
        .init(label: "F9", send: "\u{1b}[20~"), .init(label: "F10", send: "\u{1b}[21~"),
        .init(label: "F11", send: "\u{1b}[23~"), .init(label: "F12", send: "\u{1b}[24~"),
    ]
    // 展开面板：常用 shell 符号（label 即发送内容）。
    private let symbolKeys: [TermKey] = [
        "/", "\\", "|", "~", "-", "_", "=", "+", ":", ";", ",", ".", "?", "!",
        "@", "#", "$", "%", "^", "&", "*", "(", ")", "[", "]", "{", "}", "<", ">",
    ].map { TermKey(label: $0, send: $0) }

    var body: some View {
        VStack(spacing: 0) {
            if expanded {
                expandedPanel
                Rectangle().fill(M.divider).frame(height: 1)
            }
            compactRow
        }
        // 与终端同一个工作面，只用顶边 hairline 分区（「线或底色差，二选一」）。
        .background(M.surface)
        .overlay(alignment: .top) { Rectangle().fill(M.divider).frame(height: 1) }
        .animation(.easeOut(duration: 0.18), value: expanded)
    }

    // MARK: 紧凑行（始终可见）

    private var compactRow: some View {
        HStack(spacing: 6) {
            // 展开 / 收起多行面板。
            Button { expanded.toggle() } label: {
                keyCap(expanded ? "∨" : "∧", active: expanded)
            }
            .buttonStyle(MPressStyle())
            // Ctrl 粘滞修饰：点亮后下一个软键盘字符按住 Ctrl 发送（Ctrl+L/R/U……）；点其它快捷键取消。
            Button { controller.toggleControl() } label: {
                keyCap("ctrl", active: controller.controlArmed)
            }
            .buttonStyle(MPressStyle())
            // Alt/Meta 粘滞修饰：点亮后下一个软键盘字符前发 ESC（Alt+f/b/d/. ……）。
            Button { controller.toggleAlt() } label: {
                keyCap("alt", active: controller.altArmed)
            }
            .buttonStyle(MPressStyle())

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(quickKeys) { key in
                        Button { tap(key) } label: { keyCap(key.label, active: false) }
                            .buttonStyle(MPressStyle())
                    }
                }
                .padding(.trailing, 10)
            }
        }
        .padding(.leading, 10).padding(.vertical, 7)
    }

    // MARK: 展开面板（多行网格，纵向可滚）

    private var expandedPanel: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 10) {
                section("导航", navKeys)
                section("Ctrl", ctrlKeys)
                section("功能键", fnKeys)
                section("符号", symbolKeys)
            }
            .padding(.horizontal, 10).padding(.vertical, 10)
        }
        .frame(maxHeight: 220)
    }

    private func section(_ title: String, _ keys: [TermKey]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(M.sans(11, weight: .semibold)).foregroundStyle(M.text3)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 46), spacing: 6)], spacing: 6) {
                ForEach(keys) { key in
                    Button { tap(key) } label: { keyCap(key.label, active: false, expand: true) }
                        .buttonStyle(MPressStyle())
                }
            }
        }
    }

    /// 发送一个快捷键：先清掉粘滞修饰（修饰只作用于系统软键盘字符），再发字节序列。
    private func tap(_ key: TermKey) {
        controller.clearStickyModifiers()
        controller.sendText(key.send)
    }

    /// 单个键帽样式；`active` 时用强调色淡底 + 强调色字（修饰上膛态）。`expand` 时撑满网格列宽。
    private func keyCap(_ text: String, active: Bool, expand: Bool = false) -> some View {
        Text(text)
            .font(M.mono(13, weight: .medium))
            .foregroundStyle(active ? accent : M.text)
            .lineLimit(1)
            .padding(.horizontal, expand ? 4 : 12)
            .frame(maxWidth: expand ? .infinity : nil, minHeight: 34, maxHeight: 34)
            .background(active ? accent.opacity(0.14) : M.button)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
