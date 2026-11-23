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
    /// 开标签时的主机名（见 `FileTab.hostName`）。
    let hostName: String
    let controller: MobileTerminalController
    /// 远控标签：接入的是某台 Mac 上正在运行的终端，而不是手机直连这台主机。
    let remote: MRemoteSource?
    let agent = AssistantModel()
    /// Agent 在途驱动 Task 集：会话关闭时取消，停掉在途 LLM 流 / 工具循环（见 `MAgentTaskBag`）。
    let agentTasks = MAgentTaskBag()
    /// 当前是纯终端还是 Agent 模式。
    var mode: MTerminalMode = .terminal
    /// `transportFactory` 默认真 SSH——生产侧一律用 `TermTab(host:)`，行为不变；
    /// 探针注入假传输，从而在不发起任何真实连接的前提下把整屏挂起来。
    /// `hostSessionID`：App 重新打开后恢复的标签带着上次的会话 id，凭它接回主机上还在跑的那个 shell。
    init(host: ServerProfile, transportFactory: MobileTerminalTransportFactory = .live, hostSessionID: UUID? = nil) {
        self.host = host
        self.hostName = host.name
        self.remote = nil
        self.controller = MobileTerminalController(transportFactory: transportFactory, hostSessionID: hostSessionID)
    }

    /// 体验主机的标签（模拟 shell）。
    var isDemo: Bool { DemoHostProfile.isDemo(host) }
    /// 能切到 Agent：远控标签没有（Agent 跑在 Mac 那边），体验主机也没有（`run_command` 要真 SSH）。
    var offersAgent: Bool { remote == nil && !isDemo }

    /// 能开「历史会话」：直连的主机经 SFTP 读；远控标签经那台 Mac 的文件通道读，要它认得文件请求
    /// （老版本 Mac 收到不认识的消息会断开整条连接，所以不给入口）。体验主机没有真文件系统。
    var offersClaudeHistory: Bool {
        if let remote { return remote.client.supportsFiles }
        return !isDemo
    }

    /// 历史会话定位到哪个项目：直连主机按 shell 报的当前目录（OSC 7）；远控协议里没有 Mac 终端的当前目录，不定位。
    var claudeHistoryDirectory: String? {
        guard remote == nil else { return nil }
        return ClaudeProjectPath.directory(fromOSC7: controller.terminal.shadow.workingDirectory)
    }

    /// 远控标签：经 Mac 接入它上面的终端。`transportFactory` 只给截图换成写好的输出，App 里一律走默认的远控通道。
    init(host: ServerProfile, remote: MRemoteSource, transportFactory: MobileTerminalTransportFactory? = nil) {
        self.host = host
        self.hostName = host.name
        self.remote = remote
        self.controller = MobileTerminalController(
            transportFactory: transportFactory ?? .remote(client: remote.client, sessionID: remote.sessionID))
    }

    /// 标签上显示的程序状态。远控标签读 Mac 推来的（中途接入也拿得到当前状态），直连读本机解析的。
    /// 没连上就没有程序可言。
    var programStatus: ProgramStatusRecord? {
        guard controller.state == .connected else { return nil }
        if let remote { return remote.client.programStatus(for: remote.sessionID) }
        return controller.programStatus
    }

    /// 前台在跑 AI 命令行（含空闲），不是 shell。规则同 `programStatus`：远控读 Mac 推来的，直连读本机解析的。
    var agentInForeground: Bool {
        guard controller.state == .connected else { return false }
        if let remote { return remote.client.programReport(for: remote.sessionID) != nil }
        return controller.agentInForeground
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
    /// 终端区域的底色（头部 / 键盘条之外的留白随终端底色）。日间白底、暗夜卡面色 #141414（即 `M.surface`）：
    /// 终端与上下的标签条、键盘条铺同一个面，只靠 hairline 分区。
    private var terminalBg: Color {
        Color(uiColor: TerminalColorScheme.resolve(dark: colorScheme == .dark).backgroundColor)
    }
    private var serverContext: String {
        String(localized: "\(tab.host.name)（\(tab.host.displayEndpoint)）", comment: "Agent 的主机上下文：主机名（地址）")
    }

    var body: some View {
        ZStack {
            // Agent 层（底）：始终挂载，保活对话 / 草稿 / 滚动位置。
            // isActive 仅在「激活标签 + Agent 模式」时为真——后台标签不在 .auto 档自动执行命令。
            MobileAgentChat(model: tab.agent, host: tab.host, tasks: tab.agentTasks,
                            isActive: isActive && tab.mode == .agent, serverContext: serverContext)
                // 隐藏时也参与 ZStack 的尺寸：没配模型服务的空状态有固定高度，横屏键盘弹起后
                // 比可用高度还高，会把整列撑出屏幕，标签条和键盘条都看不见。不让它向外要高度。
                .frame(minHeight: 0, maxHeight: .infinity)
                .opacity(tab.mode == .agent ? 1 : 0)
                .allowsHitTesting(tab.mode == .agent)
            // 终端层（顶）：终端是 UIViewRepresentable，其 UIView 会无视 ZStack 顺序盖在
            // 上层 SwiftUI（Agent）之上，且 `.opacity(0)` 不一定作用于该 UIView——只用透明度切会
            // 出现「Agent 模式仍显示终端、切不过去」。故终端层放最上，Agent 模式时把它**移出屏外**
            //（仍挂载，保活会话与回滚缓冲，不卸载），把画面让给下面的 Agent 层。
            terminalLayer
                .allowsHitTesting(tab.mode == .terminal)
                .offset(x: tab.mode == .terminal ? 0 : -100_000)
        }
        // 终端与 Agent 两态同一个工作面（终端底色 == M.surface），切换时底色不跳。
        .background(tab.mode == .terminal ? terminalBg : M.surface, ignoresSafeAreaEdges: .mSessionBody)
        // 所有会话常驻挂载：告诉会话此刻有没有人在看它（远控的重连退避、程序状态的已读）。
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
                        MTerminalHostView(controller: tab.controller,
                                          fontSize: adaptiveFontSize(width: geo.size.width),
                                          isActive: tab.mode == .terminal,
                                          autoFocus: store.connecting == nil && isFocused,
                                          isOnScreen: isActive && tab.mode == .terminal,
                                          onInteract: onInteract)
                    }
                    // 终端页边距（对齐 macOS `TerminalContainerView` 的 8pt 左右边）：字符不再贴着屏幕
                    // 边 / 圆角；上下不留，行数才能用满。
                    // 外层不 ignoresSafeArea，横屏刘海 / iPhone Duo 侧边灵动岛仍由安全区让开，
                    // 底色（同 M.surface）则铺满安全区。
                    .padding(.horizontal, Self.terminalInset.horizontal)
                    .background(terminalBg, ignoresSafeAreaEdges: .mSessionBody)
                    .overlay(alignment: .top) {
                        VStack(spacing: 0) {
                            if tab.controller.search.isPresented {
                                MTerminalFindBar(search: tab.controller.search) { hadFocus in
                                    if hadFocus { tab.controller.focusKeyboard() }
                                }
                            }
                            statusBanner
                        }
                    }
                    TerminalKeyBar(controller: tab.controller, agentInForeground: tab.agentInForeground)
                }
            }
        }
    }

    /// 终端顶上的一条状态：正在重连、已断开（可以点重新连接）、正在连接（没有连接中页盖着时，例如 App 重新打开后恢复的标签）。
    @ViewBuilder private var statusBanner: some View {
        let controller = tab.controller
        if controller.isReconnecting {
            MTerminalReconnectBanner(notice: controller.reconnectNotice)
        } else if tab.remote == nil, controller.canReconnect {
            MTerminalDisconnectedBanner { controller.restart() }
        } else if controller.state == .connecting, store.connecting?.tabID != tab.id {
            MTerminalReconnectBanner(notice: "正在连接…")
        }
    }

    /// 终端文本区与四周的间距（pt）。
    static let terminalInset = (horizontal: CGFloat(8), vertical: CGFloat(0))

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
                    MBtn(title: String(localized: "拷贝错误"), icon: "copy", kind: .secondary, height: 44) {
                        UIPasteboard.general.string = msg
                    }.fixedSize()
                    if tab.controller.canReconnect {
                        MBtn(title: String(localized: "关闭"), kind: .secondary, height: 44, action: onClose).fixedSize()
                        MBtn(title: String(localized: "重试"), kind: .tinted, height: 44) { tab.controller.restart() }.fixedSize()
                    } else {
                        MBtn(title: String(localized: "关闭"), kind: .tinted, height: 44, action: onClose).fixedSize()
                    }
                }
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 56).padding(.horizontal, 28).padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(M.surface, ignoresSafeAreaEdges: .mSessionBody)
    }
}
