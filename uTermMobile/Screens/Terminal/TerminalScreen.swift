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

/// 终端会话集合：把 `tabs` / `activeID` 从 `TerminalScreen` 的 `@State` 上移到此处，由根视图
/// `MobileRootView` 持有并注入。这样 iPhone Plus/Max 横屏切换 size class（compact ⇄ regular）
/// 导致外壳在 `MobileTabShell` / `MobileSplitShell` 间切换、`TerminalScreen` 被重建时，会话
/// （及其 SSH 连接 / 回滚缓冲）仍存活，不会被连带销毁而「横屏自动关闭」。
@MainActor
@Observable
final class TerminalSessions {
    var tabs: [TermTab] = []
    var activeID: UUID?
}

/// 终端标签：无会话时给出主机列表；有会话时多 Tab 并存，可新建 / 切换 / 关闭。
struct TerminalScreen: View {
    @Environment(MobileStore.self) private var store
    @Environment(HostKeyChallengeRelay.self) private var relay
    @Environment(TerminalSessions.self) private var sessions
    @Environment(\.modelContext) private var context
    @Environment(\.mAccent) private var accent
    @Environment(\.colorScheme) private var colorScheme
    @Query(sort: [SortDescriptor(\ServerProfile.sortOrder)]) private var hosts: [ServerProfile]

    // 会话状态存活在 `sessions`（根视图持有），跨外壳切换不丢；这里以计算属性透出，
    // 沿用原有 `tabs` / `activeID` 读写点，改动最小。
    private var tabs: [TermTab] {
        get { sessions.tabs }
        nonmutating set { sessions.tabs = newValue }
    }
    private var activeID: UUID? {
        get { sessions.activeID }
        nonmutating set { sessions.activeID = newValue }
    }
    @State private var picking = false
    /// 会话进行中时返回主机列表（会话不断、仍可回到）。
    @State private var showPicker = false

    private var connectable: [ServerProfile] { hosts.filter { !$0.sftpOnly } }
    private var terminalBg: Color { MTerminalColors.background(dark: colorScheme == .dark) }

    var body: some View {
        ZStack {
            if tabs.isEmpty || showPicker {
                picker.transition(.mFade)
            } else {
                sessionContainer.transition(.mDrill)
            }
        }
        .animation(.mSwap, value: tabs.isEmpty)
        .animation(.mSwap, value: showPicker)
        .onChange(of: store.terminalTarget) { _, t in consumeTarget(t) }
        .onAppear { consumeTarget(store.terminalTarget) }
        .onChange(of: activeID) { _, id in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                // 连接中页期间不要弹键盘——键盘窗口恒在最上，会盖住中转页的取消按钮。
                guard store.connecting == nil else { return }
                guard let tab = tabs.first(where: { $0.id == id }) else { return }
                if tab.mode == .terminal {
                    // 终端会话：becomeFirstResponder 隐式接管旧响应者，无闪烁。
                    tab.controller.focusKeyboard()
                } else {
                    // 切到 Agent 会话：没有终端去接管第一响应者，主动全局收起旧键盘
                    // （旧终端或上一个 Agent 输入框），否则击键会落到隐藏的旧会话。
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                    to: nil, from: nil, for: nil)
                }
            }
        }
        // 离开终端标签时收起键盘（否则键盘会残留到其它标签之上）；回到时重新聚焦。
        .onChange(of: store.tab) { _, t in
            if t == .terminal { focusActiveTerminal() } else { resignActive() }
        }
        // 返回主机列表（会话不断）时收起键盘；回到会话时重新聚焦。
        .onChange(of: showPicker) { _, picking in
            if picking { resignActive() } else { focusActiveTerminal() }
        }
        // 连接中页撤下（连接完成）后再弹键盘——建连期刻意不弹（见 SwiftTermView.autoFocus）。
        .onChange(of: store.connecting?.id) { _, id in
            if id == nil { focusActiveTerminal() }
        }
        // 连接中页取消 / 重试：拆掉对应会话 tab 的视图状态（控制器已由 store 关闭）。
        .onChange(of: store.terminalTeardownID) { _, id in
            guard let id else { return }
            if let tab = tabs.first(where: { $0.id == id }) {
                tab.controller.resignKeyboard()
                tab.agent.dispose()
                tab.agentTasks.cancelAll()
            }
            tabs.removeAll { $0.id == id }
            if activeID == id { activeID = tabs.last?.id }
            if tabs.isEmpty { showPicker = false }
            store.terminalTeardownID = nil
        }
        .sheet(isPresented: $picking) { newTabSheet }
    }

    // MARK: - 标签管理

    /// 外部「连接终端」请求（来自主机列表 / 详情 / 命令面板）：
    /// 聚焦同主机已存在的会话，否则新开一个。
    private func consumeTarget(_ t: PersistentIdentifier?) {
        guard let t else { return }
        store.terminalTarget = nil
        guard let host = hosts.first(where: { $0.persistentModelID == t }), !host.sftpOnly else {
            // 找不到主机 / 仅 SFTP：开不了终端会话——撤下正在等待绑定的连接中页，避免空转卡死。
            if let req = store.connecting, req.kind == .terminal, req.terminal == nil,
               req.host.persistentModelID == t {
                store.cancelConnect()
            }
            return
        }
        openTab(host, allowDuplicate: store.connecting?.allowDuplicate ?? false)
    }

    private func openTab(_ host: ServerProfile, allowDuplicate: Bool) {
        if !allowDuplicate,
           let existing = tabs.first(where: { $0.host.persistentModelID == host.persistentModelID }) {
            activeID = existing.id
            bindConnecting(existing)   // 已有会话（多半已连）：让连接中页据其状态立即收尾
            return
        }
        let tab = TermTab(host: host)
        tab.controller.start(profile: host, container: context.container, relay: relay)
        tabs.append(tab)
        activeID = tab.id
        bindConnecting(tab)
    }

    /// 若此次开 tab 由连接中页发起，则把会话控制器回填给请求，供连接中页观察真实状态并推进阶段。
    private func bindConnecting(_ tab: TermTab) {
        guard let req = store.connecting, req.kind == .terminal, req.terminal == nil,
              req.host.persistentModelID == tab.host.persistentModelID else { return }
        req.terminal = tab.controller
        req.terminalTabID = tab.id
    }

    private func closeTab(_ id: UUID) {
        if let tab = tabs.first(where: { $0.id == id }) {
            tab.controller.resignKeyboard()
            tab.controller.close()
            tab.agent.dispose()
            tab.agentTasks.cancelAll()
        }
        tabs.removeAll { $0.id == id }
        if activeID == id { activeID = tabs.last?.id }
        if tabs.isEmpty { showPicker = false }
    }

    /// 切换当前会话的「终端 ⇄ Agent」模式（对齐 macOS 终端窗口的分段开关）。
    private func toggleAgent() {
        guard let tab = tabs.first(where: { $0.id == activeID }) else { return }
        withAnimation(.easeInOut(duration: 0.16)) {
            tab.mode = tab.mode == .agent ? .terminal : .agent
        }
        // 收/放终端键盘，避免两套输入框抢焦点。
        if tab.mode == .agent { tab.controller.resignKeyboard() } else { tab.controller.focusKeyboard() }
    }

    /// 收起当前会话的终端键盘（离开终端 / 返回列表时）。
    private func resignActive() {
        tabs.first { $0.id == activeID }?.controller.resignKeyboard()
    }
    /// 重新聚焦当前会话的终端（回到终端标签 / 会话时弹回键盘）。
    private func focusActiveTerminal() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard store.connecting == nil, store.tab == .terminal, !showPicker,
                  let tab = tabs.first(where: { $0.id == activeID }), tab.mode == .terminal else { return }
            tab.controller.focusKeyboard()
        }
    }

    // MARK: - 多 Tab 会话

    private var sessionContainer: some View {
        VStack(spacing: 0) {
            SessionTabBar(tabs: tabs, activeID: activeID,
                          onSelect: { activeID = $0 }, onClose: closeTab,
                          onNew: { picking = true }, onBack: { showPicker = true },
                          onAgent: toggleAgent)
            ZStack {
                ForEach(tabs) { tab in
                    TerminalSessionBody(tab: tab, isActive: tab.id == activeID,
                                        onClose: { closeTab(tab.id) })
                        .opacity(tab.id == activeID ? 1 : 0)
                        .allowsHitTesting(tab.id == activeID)
                }
            }
        }
        .background(terminalBg)
    }

    // MARK: - 主机选择

    private var picker: some View {
        MScreen(title: "终端", actions: {
            if !tabs.isEmpty {
                Button { showPicker = false } label: {
                    HStack(spacing: 5) {
                        MIcon(name: "term", size: 14, color: accent)
                        Text("会话 \(tabs.count)").font(M.sans(13, weight: .medium)).foregroundStyle(accent)
                    }
                    .padding(.horizontal, 11).frame(height: 32)
                    .background(accent.opacity(0.12)).clipShape(Capsule())
                }
                .buttonStyle(MPressStyle())
            }
        }) {
            VStack(spacing: 10) {
                if connectable.isEmpty {
                    MEmptyState(icon: "term", title: "没有可连接的主机",
                                message: "先在「主机」里添加一台支持终端的服务器。")
                } else {
                    Text("选择一台主机开始终端会话")
                        .font(M.sans(13)).foregroundStyle(M.text3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20).padding(.top, 4)
                    MCardList {
                        ForEach(connectable) { host in
                            // 走连接中页（与主机详情 / 命令面板一致）；showPicker 先关，连接完成后露出会话。
                            hostRow(host) { showPicker = false; store.openTerminal(host) }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }

    private var newTabSheet: some View {
        NavigationStack {
            ScrollView {
                MCardList {
                    if connectable.isEmpty {
                        Text("没有可连接的主机").font(M.sans(14)).foregroundStyle(M.text3)
                            .frame(maxWidth: .infinity).padding(.top, 40)
                    } else {
                        ForEach(connectable) { host in
                            // 新建终端会话也走连接中页（强制新开一个会话）。
                            hostRow(host) {
                                picking = false
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    store.requestConnect(host, kind: .terminal, allowDuplicate: true)
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(M.canvas)
            .navigationTitle("新建终端")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { picking = false } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func hostRow(_ host: ServerProfile, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                MIcon(name: "server", size: 18, color: accent)
                    .frame(width: 38, height: 38)
                    .background(accent.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text(host.name).font(M.sans(15.5, weight: .semibold)).foregroundStyle(M.text)
                    Text(host.displayEndpoint).font(M.mono(12)).foregroundStyle(M.text3)
                }
                Spacer()
                MIcon(name: "run", size: 15, color: accent)
            }
            .padding(14)
            .background(M.card)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .udShadow(.sm)
        }
        .buttonStyle(MPressStyle())
    }
}

// MARK: - 会话标签栏（设计稿 TerminalBody 的标签行）

struct SessionTabBar: View {
    let tabs: [TermTab]
    let activeID: UUID?
    var onSelect: (UUID) -> Void
    var onClose: (UUID) -> Void
    var onNew: () -> Void
    var onBack: () -> Void
    /// 切换当前会话的「终端 ⇄ Agent」模式。
    var onAgent: () -> Void
    @Environment(\.mAccent) private var accent

    /// 当前活动会话是否处于 Agent 模式。
    private var agentOn: Bool { tabs.first { $0.id == activeID }?.mode == .agent }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                MIcon(name: "back", size: 19, color: accent, weight: .semibold)
                    .frame(width: 34, height: 34)
                    .background(M.fillFaint).clipShape(Circle())
            }
            .buttonStyle(MPressStyle())

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(tabs) { tab in chip(tab) }
                    Button(action: onNew) {
                        MIcon(name: "plus", size: 14, color: M.text2, weight: .semibold)
                            .frame(width: 30, height: 30)
                            .background(M.fillFaint)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(MPressStyle())
                }
            }

            Button(action: onAgent) {
                MIcon(name: agentOn ? "term" : "spark", size: 17,
                      color: agentOn ? .white : M.aiAccent, weight: .semibold)
                    .frame(width: 34, height: 34)
                    .background(agentOn ? M.aiAccent : M.aiAccent.opacity(0.15))
                    .clipShape(Circle())
            }
            .buttonStyle(MPressStyle())
            .accessibilityLabel(Text(agentOn ? "返回终端" : "切换到 Agent"))
            .accessibilityAddTraits(agentOn ? [.isButton, .isSelected] : .isButton)
        }
        .padding(.horizontal, 12).frame(height: 48)
        // v2 禁半透明材质浮层：实体 overlay 面 + 发丝分隔（贴边 bar 不带投影）
        .background(M.overlay)
        .overlay(alignment: .bottom) { Rectangle().fill(M.divider).frame(height: 1) }
    }

    private func chip(_ tab: TermTab) -> some View {
        let on = tab.id == activeID
        return HStack(spacing: 6) {
            MDot(color: dotColor(tab.controller.state), pulse: tab.controller.state == .connecting, size: 6)
            Text(tab.controller.title.isEmpty ? tab.host.name : tab.controller.title)
                .font(M.mono(12.5, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? accent : M.text3).lineLimit(1)
            Button { onClose(tab.id) } label: {
                MIcon(name: "x", size: 11, color: on ? accent : M.text4, weight: .semibold)
                    .padding(3).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 11).padding(.trailing, 6).frame(height: 30)
        .background(on ? accent.opacity(0.14) : M.fillFaint)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { onSelect(tab.id) }
    }

    private func dotColor(_ s: MobileTerminalController.State) -> Color {
        switch s {
        case .connected: return M.success
        case .connecting: return M.warning
        case .failed: return M.danger
        case .closed, .idle: return M.text4
        }
    }
}

// MARK: - 单个会话主体：终端 + 键盘条，或失败态

struct TerminalSessionBody: View {
    let tab: TermTab
    /// 该会话是否为当前激活标签（用于 Agent 仅在前台自动批准命令）。
    var isActive: Bool = false
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
        .background(tab.mode == .terminal ? terminalBg : M.canvas)
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
                                      autoFocus: store.connecting == nil)
                    }
                    .background(terminalBg)
                    TerminalKeyBar(controller: tab.controller)
                }
            }
        }
    }

    /// 终端字号随可用宽度自适应：以 iPhone 14/15 竖屏逻辑宽度 390pt 为参考点对应 11pt 基准，
    /// 按比例缩放并夹在可读区间 [9, 16]——窄屏（SE）字更小以容纳更多列，宽屏（Pro Max /
    /// iPad / 分屏）字更大。
    private func adaptiveFontSize(width: CGFloat) -> CGFloat {
        guard width > 0 else { return 11 }
        let reference: CGFloat = 390, base: CGFloat = 11
        return min(max(base * width / reference, 9), 16)
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
        .background(M.bg)
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
        // v2 禁半透明材质浮层：实体 overlay 面 + 发丝分隔（贴边 bar 不带投影）
        .background(M.overlay)
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
            .background(active ? accent.opacity(0.14) : M.panelHi)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
