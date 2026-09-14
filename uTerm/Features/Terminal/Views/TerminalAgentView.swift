import AgentKit
import UDesignKit
import SwiftUI
import SwiftData

/// 终端窗口的「纯 Agent 模式」：用自然语言驱动运维。对齐设计稿 `pages/terminal-agent.jsx`。
///
/// 布局：上下文条（主机 · 历史 · 新对话）→ 居中对话区（max 760；空状态居中、命令卡
/// 整宽 = 真实 `run_command` 工具调用）→ 输入区
/// （安全档位拨盘 + 模型胶囊 + 发送）。
/// 复用 `AssistantModel`（真实流式 + 工具审批）与 DesignKit `UDToolCall` / `UDComposer`。
struct TerminalAgentView: View {
    @Bindable var model: AssistantModel
    let host: String
    let serverContext: String
    @Binding var safety: AgentSafety
    @Binding var activeProviderIDString: String
    let onOpenSettings: () -> Void
    /// 一次最多挂载多少条消息（`AgentMessageWindow`）。与工作区 Agent 面板同一形态、
    /// 同一处方：`docs/scroll-perf-findings.md`「Agent 消息流」。
    var messageWindowLimit: Int = AgentMessageWindow.defaultLimit

    @Environment(\.modelContext) private var modelContext
    // 同 `AssistantView`：会话历史只取最近 `ChatSessionQueries.recentLimit` 条。
    @Query(ChatSessionQueries.recent) private var sessions: [ChatSession]
    @State private var followsConversationTail = true
    @State private var pendingTailScroll: DispatchWorkItem?
    /// 用户点开「显示更早」后放大的上限；`nil` 表示仍用 `messageWindowLimit`。
    @State private var expandedWindowLimit: Int?

    var body: some View {
        Group {
            if model.providers.isEmpty {
                emptyProviderState
            } else {
                VStack(spacing: 0) {
                    contextBar
                    conversation
                    composer
                }
                .background(commandReturnShortcut)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(UD.bg)
        .onAppear {
            model.approvalMode = safety
            model.attach(context: modelContext)
        }
        .onChange(of: safety) { _, value in model.approvalMode = value }
    }

    // MARK: - 上下文条

    private var contextBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock").font(.system(size: 11)).foregroundStyle(UD.text3)
            Text("上下文").font(.system(size: 11.5)).foregroundStyle(UD.text2)
            Text(host).font(UD.mono(11)).foregroundStyle(UD.text3)
            Spacer(minLength: 8)

            UDDropdown(anchor: .trailing) { _ in
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 12)).foregroundStyle(UD.text3)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            } content: {
                UDMenu(width: 240, head: "会话历史", maxHeight: 320, items: sessionMenuItems)
            }
            .fixedSize()
            .accessibilityLabel("会话历史")
            .help("会话历史")

            Button { model.startNewSession() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12)).foregroundStyle(UD.text3)
                    .frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("新对话").accessibilityLabel("新对话")
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(UD.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(UD.border).frame(height: 1) }
    }

    // MARK: - 对话区

    @ViewBuilder
    private var conversation: some View {
        if model.messages.isEmpty {
            // 空状态：居中铺满（不进 ScrollView），避免内容偏上 + 出现滚动条。
            // 加宽到 640，使每组 3 条建议能并排放在同一行。
            emptyState
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 24)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        earlierMessagesButton
                        ForEach(mountedMessages) { messageRow($0) }
                        Color.clear.frame(height: 1).id(Self.bottomAnchorID)
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                }
                .frame(maxHeight: .infinity)
                // 默认贴底；新消息 / 流式增量 / 工具状态变化都滚到底（工具卡输出
                // 增长不改 message.text，故还要听 messages.count 与 state）。
                .defaultScrollAnchor(.bottom)
                .onScrollPhaseChange { _, phase, context in
                    if phase == .tracking || phase == .interacting {
                        followsConversationTail = false
                        pendingTailScroll?.cancel()
                        pendingTailScroll = nil
                    }
                    if phase == .idle {
                        followsConversationTail = AgentScrollPolicy.isNearBottom(
                            visibleMaxY: context.geometry.visibleRect.maxY,
                            contentHeight: context.geometry.contentSize.height)
                    }
                }
                .onChange(of: model.messages.count) { _, _ in scheduleScrollToBottom(proxy) }
                // 换会话时把渲染窗口收回默认值。
                .onChange(of: model.messages.first?.id) { _, _ in expandedWindowLimit = nil }
                .onChange(of: model.messages.last?.text) { _, _ in scheduleScrollToBottom(proxy) }
                .onChange(of: model.state) { _, _ in scheduleScrollToBottom(proxy) }
                .onDisappear {
                    pendingTailScroll?.cancel()
                    pendingTailScroll = nil
                }
            }
        }
    }

    // MARK: - 渲染窗口

    private var effectiveWindowLimit: Int {
        max(expandedWindowLimit ?? messageWindowLimit, 1)
    }

    /// 真正挂进视图树的那一段；`model.messages` / SwiftData / 模型上下文一条不裁。
    private var mountedMessages: ArraySlice<ChatMessage> {
        let start = AgentMessageWindow.startIndex(count: model.messages.count,
                                                  limit: effectiveWindowLimit)
        return model.messages[start...]
    }

    @ViewBuilder
    private var earlierMessagesButton: some View {
        let hidden = AgentMessageWindow.hiddenCount(count: model.messages.count,
                                                    limit: effectiveWindowLimit)
        if hidden > 0 {
            HStack {
                Spacer(minLength: 0)
                Button {
                    expandedWindowLimit = AgentMessageWindow.expanded(
                        effectiveWindowLimit, count: model.messages.count)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 9, weight: .semibold))
                        Text("显示更早的 \(min(hidden, AgentMessageWindow.step)) 条")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(UD.text3)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(Capsule().fill(UD.fillSoft))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("显示更早的消息，还有 \(hidden) 条")
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private static let bottomAnchorID = "ta.bottom"

    private func scheduleScrollToBottom(_ proxy: ScrollViewProxy) {
        guard followsConversationTail, pendingTailScroll == nil else { return }
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                pendingTailScroll = nil
                // 滚到对话末尾的贴底锚点；合并到最多每 100ms 一次，与 Markdown
                // 重排节奏一致，避免逐 token 重入 LazyVStack 布局。
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
        }
        pendingTailScroll = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + AgentScrollPolicy.coalescingDelay,
            execute: work)
    }

    @ViewBuilder
    private func messageRow(_ m: ChatMessage) -> some View {
        if m.role == .user {
            HStack {
                Spacer(minLength: 40)
                Text(m.text)
                    .font(.system(size: 13))
                    .foregroundStyle(UD.text)
                    .textSelection(.enabled)
                    .padding(.vertical, 10).padding(.horizontal, 13)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(UD.accentSoft))
            }
            .id(m.id)
        } else {
            // 文本带头像；命令卡整宽（不跟随头像缩进 → 左右对称，去掉头像下方竖直空槽）。
            VStack(alignment: .leading, spacing: 8) {
                if !m.text.isEmpty {
                    HStack(alignment: .top, spacing: 10) {
                        agentAvatar
                        StreamingMarkdownView(text: m.text, isStreaming: isStreamingTail(m))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else if !isStreamingTail(m) && m.toolCalls.isEmpty {
                    HStack(alignment: .top, spacing: 10) {
                        agentAvatar
                        Text("…").font(.system(size: 13)).foregroundStyle(UD.text3)
                    }
                }
                ForEach(m.toolCalls) { call in
                    UDToolCall(
                        label: call.explanation ?? "运行命令",
                        command: call.command,
                        status: udStatus(call),
                        approvalEnabled: model.state == .awaitingApproval,
                        onRun: { Task { await model.approveAndRun(id: call.id) } },
                        onSkip: { Task { await model.skip(id: call.id) } })
                    if let summary = model.approvalSummary(for: call) {
                        Text(summary).font(.caption).foregroundStyle(UD.text3)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .id(m.id)
        }
    }

    private var agentAvatar: some View {
        Image(systemName: "sparkles")
            .font(.system(size: 12))
            .foregroundStyle(UD.accent)
            .frame(width: 22, height: 22)
            .background(RoundedRectangle(cornerRadius: 7).fill(UD.accentSoft))
    }

    private func isStreamingTail(_ m: ChatMessage) -> Bool {
        m.id == model.messages.last?.id && model.state == .streaming
    }

    private func udStatus(_ call: ToolCallState) -> UDToolCall.Status {
        switch call.status {
        case .pending: return .pending
        case .running: return .running
        case .done, .failed, .skipped: return .done(output: call.output)
        }
    }

    private func firstPendingToolCallID() -> String? {
        for m in model.messages {
            if let c = m.toolCalls.first(where: { $0.status == .pending }) { return c.id }
        }
        return nil
    }

    // MARK: - 空状态（按诊断 / 配置 / 部署分组的示例，居中）

    private var emptyState: some View {
        VStack(spacing: 22) {
            VStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 24)).foregroundStyle(UD.accent)
                    .frame(width: 48, height: 48)
                    .background(RoundedRectangle(cornerRadius: 14).fill(UD.accentSoft))
                VStack(spacing: 5) {
                    Text("用自然语言操作 \(host)")
                        .font(.system(size: 16, weight: .medium)).foregroundStyle(UD.text)
                        .multilineTextAlignment(.center)
                    Text("描述你想做的事，Agent 会翻译成命令、征求确认后在远端执行。")
                        .font(.system(size: 12.5)).foregroundStyle(UD.text3)
                        .multilineTextAlignment(.center)
                }
            }

            VStack(spacing: 14) {
                ForEach(Self.emptyGroups, id: \.tag) { group in
                    VStack(spacing: 8) {
                        // 分组标题居中
                        Text(group.tag)
                            .font(.system(size: 10.5, weight: .medium))
                            .tracking(0.5).foregroundStyle(UD.text4)
                            .frame(maxWidth: .infinity, alignment: .center)
                        // 同组建议放在同一行（居中、不换行）。
                        HStack(spacing: 8) {
                            ForEach(group.items, id: \.self) { item in
                                Button { model.input = item } label: { exampleChip(item) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func exampleChip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12)).foregroundStyle(UD.text2)
            .multilineTextAlignment(.center)
            .padding(.vertical, 7).padding(.horizontal, 11)
            .background(RoundedRectangle(cornerRadius: 8).fill(UD.fillFaint))
            .contentShape(Rectangle())
    }

    // MARK: - 输入区

    @ViewBuilder
    private var composer: some View {
        AgentStopControl(model: model)
            .padding(.horizontal, 24)
        UDComposer(
            text: $model.input,
            placeholder: "用自然语言描述你想做的事…  例如：把 nginx 日志限制到 100M",
            minLines: 3,
            queueing: model.isBusy,
            onSend: sendInput,
            onAttach: attachContext
        ) {
            HStack(spacing: 6) {
                SafetyDial(safety: $safety)
                modelPill
            }
        }
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24).padding(.top, 10).padding(.bottom, 14)
        .background(UD.bg)
        .overlay(alignment: .top) { Rectangle().fill(UD.border).frame(height: 1) }
    }

    private func attachContext() {
        let snippet = "上下文：\n\(serverContext)"
        if model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            model.input = snippet
        } else {
            model.input += "\n\n\(snippet)"
        }
    }

    /// 发送当前输入：**同步**清空输入再异步发送 —— 避免回车后「先全选再发」的闪烁。
    private func sendInput() {
        let text = model.input
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        model.input = ""
        Task { await model.submit(text: text, serverContext: serverContext) }
    }

    /// ⌘↵：有待确认命令则运行首个 pending；否则发送当前输入。
    private func handleCommandReturn() {
        if model.state == .awaitingApproval, let id = firstPendingToolCallID() {
            Task { await model.approveAndRun(id: id) }
        } else {
            sendInput()
        }
    }

    /// 承载 ⌘↵ 快捷键的 0 尺寸隐藏按钮（命令卡「运行 ⌘↵」/ 回车发送都靠它）。
    private var commandReturnShortcut: some View {
        Button("", action: handleCommandReturn)
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(.plain)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }

    private var modelPill: some View {
        UDDropdown(anchor: .leading) { _ in
            UDModelPillLabel(modelPillLabel)
        } content: {
            UDMenu(width: 240, head: "模型", maxHeight: 320, items: modelPillItems)
        }
        .fixedSize()
    }

    private var sessionMenuItems: [UDMenuItem] {
        guard !sessions.isEmpty else {
            return [UDMenuItem(label: "还没有历史会话")]
        }
        return sessions.map { session in
            UDMenuItem(
                label: session.title.isEmpty ? "新对话" : session.title,
                active: session.id == model.currentSession?.id,
                action: { model.load(session) })
        }
    }

    private var modelPillItems: [UDMenuItem] {
        var items = model.providers.map { provider in
            let label = provider.model.isEmpty
                ? provider.name
                : "\(provider.name) · \(provider.model)"
            return UDMenuItem(
                label: label,
                active: provider.id == model.activeProvider?.id,
                action: { activeProviderIDString = provider.id.uuidString })
        }
        items.append(.divider())
        items.append(UDMenuItem(label: "管理…", action: onOpenSettings))
        return items
    }

    private var modelPillLabel: String {
        let raw = model.activeProvider.map { $0.model.isEmpty ? $0.name : $0.model } ?? "未选择"
        return raw.count > 22 ? String(raw.prefix(21)) + "…" : raw
    }

    // MARK: - 0 provider 空状态

    private var emptyProviderState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles").font(.largeTitle).foregroundStyle(UD.text3)
            Text("还没添加 AI Provider").font(.headline).foregroundStyle(UD.text)
            Text("在 Settings 添加一个 Anthropic / OpenAI 配置。")
                .font(.caption).foregroundStyle(UD.text3).multilineTextAlignment(.center)
            UDButton(title: "打开 Settings", systemImage: "gearshape") { onOpenSettings() }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 示例数据（建议 / 空状态分组）

    private struct EmptyGroup { let tag: String; let items: [String] }
    private static let emptyGroups: [EmptyGroup] = [
        .init(tag: "诊断", items: ["根分区是什么占满的", "最近的 5xx 集中在什么时间", "CPU 突然飙高是哪个进程"]),
        .init(tag: "配置", items: ["给 upstream 加上 keepalive", "把 SSH 端口改成 2222", "开启 gzip 压缩"]),
        .init(tag: "部署", items: ["拉取最新代码并重启服务", "回滚到上一个版本", "查看 systemd 服务状态"]),
    ]
}

// MARK: - 安全档位拨盘

/// 输入区左下角的「自然语言 → 执行」信任拨盘（设计稿 terminal-agent.jsx 的安全档位）。
struct SafetyDial: View {
    @Binding var safety: AgentSafety

    var body: some View {
        UDDropdown(anchor: .leading) { open in
            HStack(spacing: 6) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 11)).foregroundStyle(UD.accent)
                Text(safety.label).font(.system(size: 11.5)).foregroundStyle(UD.text2)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold)).foregroundStyle(UD.text4)
                    .rotationEffect(.degrees(open ? 180 : 0))
            }
            .padding(.leading, 9).padding(.trailing, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(UD.fillFaint))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        } content: {
            UDMenu(width: 180, items: AgentSafety.allCases.map { mode in
                UDMenuItem(label: mode.label, active: mode == safety, action: { safety = mode })
            })
        }
        .fixedSize()
        .accessibilityLabel("审批模式")
        .accessibilityValue(safety.label)
        .help(safety.detail)
    }
}
