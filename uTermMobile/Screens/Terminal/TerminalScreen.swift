import SwiftUI
import SwiftData
import Observation

/// 终端连接页内容两态：纯终端 ⇄ Agent 自然语言（对齐 macOS 终端窗口的 `TerminalWindowContentMode`）。
enum MTerminalMode: Hashable { case terminal, agent }

/// 一个终端会话标签：一台主机 + 独立 `MobileTerminalController`（独立 SSH 会话）+
/// 该会话专属的 `MobileAgentController`（Agent 模式对话，跨「终端 / Agent」切换保活）。
/// 引用类型：放进 `@State` 数组里，跨标签切换时会话与回滚缓冲都保活。
/// `@Observable` —— `mode` 切换驱动标签栏开关与会话主体重渲染。
@MainActor
@Observable
final class TermTab: Identifiable {
    let id = UUID()
    let host: ServerProfile
    let controller = MobileTerminalController()
    let agent = MobileAgentController()
    /// 当前是纯终端还是 Agent 模式。
    var mode: MTerminalMode = .terminal
    init(host: ServerProfile) { self.host = host }
}

/// 终端标签：无会话时给出主机列表；有会话时多 Tab 并存，可新建 / 切换 / 关闭。
struct TerminalScreen: View {
    @Environment(MobileStore.self) private var store
    @Environment(HostKeyChallengeRelay.self) private var relay
    @Environment(\.modelContext) private var context
    @Environment(\.mAccent) private var accent
    @Environment(\.colorScheme) private var colorScheme
    @Query(sort: [SortDescriptor(\ServerProfile.sortOrder)]) private var hosts: [ServerProfile]

    @State private var tabs: [TermTab] = []
    @State private var activeID: UUID?
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
        .sheet(isPresented: $picking) { newTabSheet }
    }

    // MARK: - 标签管理

    /// 外部「连接终端」请求（来自主机列表 / 详情 / 命令面板）：
    /// 聚焦同主机已存在的会话，否则新开一个。
    private func consumeTarget(_ t: PersistentIdentifier?) {
        guard let t else { return }
        store.terminalTarget = nil
        if let host = hosts.first(where: { $0.persistentModelID == t }), !host.sftpOnly {
            openTab(host, allowDuplicate: false)
        }
    }

    private func openTab(_ host: ServerProfile, allowDuplicate: Bool) {
        if !allowDuplicate,
           let existing = tabs.first(where: { $0.host.persistentModelID == host.persistentModelID }) {
            activeID = existing.id
            return
        }
        let tab = TermTab(host: host)
        tab.controller.start(profile: host, container: context.container, relay: relay)
        tabs.append(tab)
        activeID = tab.id
    }

    private func closeTab(_ id: UUID) {
        if let tab = tabs.first(where: { $0.id == id }) {
            tab.controller.resignKeyboard()
            tab.controller.close()
            tab.agent.stop()
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
            guard !showPicker,
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
                    TerminalSessionBody(tab: tab, onClose: { closeTab(tab.id) })
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
                    LazyVStack(spacing: 10) {
                        ForEach(connectable) { host in
                            hostRow(host) { openTab(host, allowDuplicate: false); showPicker = false }
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
                LazyVStack(spacing: 10) {
                    if connectable.isEmpty {
                        Text("没有可连接的主机").font(M.sans(14)).foregroundStyle(M.text3)
                            .frame(maxWidth: .infinity).padding(.top, 40)
                    } else {
                        ForEach(connectable) { host in
                            hostRow(host) { openTab(host, allowDuplicate: true); picking = false }
                        }
                    }
                }
                .padding(16)
            }
            .background(M.bg)
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
            .background(M.panel)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(M.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 14))
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
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(M.border, lineWidth: 1))
                    }
                    .buttonStyle(MPressStyle())
                }
            }

            Button(action: onAgent) {
                MIcon(name: agentOn ? "term" : "spark", size: 17,
                      color: agentOn ? .white : M.aiAccent, weight: .semibold)
                    .frame(width: 34, height: 34)
                    .background(agentOn ? M.aiAccent : M.aiAccent.opacity(0.12))
                    .overlay(Circle().stroke(agentOn ? .clear : M.aiAccent.opacity(0.3), lineWidth: 1))
                    .clipShape(Circle())
            }
            .buttonStyle(MPressStyle())
            .accessibilityLabel(Text(agentOn ? "返回终端" : "切换到 Agent"))
            .accessibilityAddTraits(agentOn ? [.isButton, .isSelected] : .isButton)
        }
        .padding(.horizontal, 12).frame(height: 48)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) { Rectangle().fill(M.border).frame(height: 1) }
    }

    private func chip(_ tab: TermTab) -> some View {
        let on = tab.id == activeID
        return HStack(spacing: 6) {
            MDot(color: dotColor(tab.controller.state), pulse: tab.controller.state == .connecting, size: 6)
            Text(tab.controller.title.isEmpty ? tab.host.name : tab.controller.title)
                .font(M.mono(12.5, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? M.text : M.text3).lineLimit(1)
            Button { onClose(tab.id) } label: {
                MIcon(name: "x", size: 11, color: on ? M.text2 : M.text4, weight: .semibold)
                    .padding(3).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 11).padding(.trailing, 6).frame(height: 30)
        .background(on ? accent.opacity(0.15) : Color.clear)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? accent.opacity(0.5) : M.border, lineWidth: 1))
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
    var onClose: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    private var terminalBg: Color { MTerminalColors.background(dark: colorScheme == .dark) }
    private var serverContext: String { "\(tab.host.name)（\(tab.host.displayEndpoint)）" }

    var body: some View {
        ZStack {
            // Agent 层（底）：始终挂载，保活对话 / 草稿 / 滚动位置。
            MobileAgentChat(controller: tab.agent, serverContext: serverContext)
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
        .background(tab.mode == .terminal ? terminalBg : M.bg)
    }

    private var terminalLayer: some View {
        Group {
            if case .failed(let msg) = tab.controller.state {
                failedView(msg)
            } else {
                VStack(spacing: 0) {
                    SwiftTermView(controller: tab.controller, isActive: tab.mode == .terminal)
                        .background(terminalBg)
                    TerminalKeyBar(controller: tab.controller)
                }
            }
        }
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

    private let keys: [(String, String)] = [
        ("esc", "\u{1b}"), ("tab", "\t"), ("⌃C", "\u{03}"), ("⌃D", "\u{04}"),
        ("↑", "\u{1b}[A"), ("↓", "\u{1b}[B"), ("←", "\u{1b}[D"), ("→", "\u{1b}[C"),
        ("/", "/"), ("|", "|"), ("~", "~"), ("-", "-"),
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(keys, id: \.0) { key in
                    Button { controller.sendText(key.1) } label: {
                        Text(key.0)
                            .font(M.mono(13, weight: .medium))
                            .foregroundStyle(M.text)
                            .padding(.horizontal, 12).frame(height: 34)
                            .background(M.panelHi)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(M.border, lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(MPressStyle())
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
        }
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Rectangle().fill(M.border).frame(height: 1) }
    }
}
