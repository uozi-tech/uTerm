import UAppKitBridge
import AgentKit
import AppKit
import UDesignKit
import SwiftUI
import SwiftData

/// 与文件路径栏、UPaneGroupArea 标签栏统一：36pt，底部 1pt 分隔线画在这 36pt 之内。
enum AssistantHeaderLayout {
    nonisolated static let height = WorkspacePaneHeaderLayout.height
    /// 会话历史下拉的顶部内边距：顶栏高 + 2pt 间隙。
    nonisolated static let dropdownTopInset: CGFloat = height + 2
}

/// Tool-call states stay domain-level in `ToolCallState`; this value translates them into the
/// richer labels used by the Agent surface without collapsing failures and skips into success.
nonisolated struct AgentToolCallPresentation: Equatable, Sendable {
    enum Tone: Equatable, Sendable {
        case accent, success, warning, danger, muted
    }

    let title: String
    let systemImage: String
    let tone: Tone
    let isProgressVisible: Bool
    let isApprovalVisible: Bool

    static func resolve(_ call: ToolCallState) -> AgentToolCallPresentation {
        switch call.status {
        case .pending:
            return AgentToolCallPresentation(
                title: "等待确认", systemImage: "hand.raised.fill", tone: .warning,
                isProgressVisible: false, isApprovalVisible: true)
        case .running:
            return AgentToolCallPresentation(
                title: "执行中", systemImage: "terminal.fill", tone: .accent,
                isProgressVisible: true, isApprovalVisible: false)
        case .done:
            if let exitCode = call.exitCode, exitCode != 0 {
                return AgentToolCallPresentation(
                    title: "退出码 \(exitCode)", systemImage: "exclamationmark.triangle.fill",
                    tone: .danger, isProgressVisible: false, isApprovalVisible: false)
            }
            return AgentToolCallPresentation(
                title: "已完成", systemImage: "checkmark.circle.fill", tone: .success,
                isProgressVisible: false, isApprovalVisible: false)
        case .failed:
            return AgentToolCallPresentation(
                title: "执行失败", systemImage: "xmark.circle.fill", tone: .danger,
                isProgressVisible: false, isApprovalVisible: false)
        case .skipped:
            return AgentToolCallPresentation(
                title: "已跳过", systemImage: "forward.end.fill", tone: .muted,
                isProgressVisible: false, isApprovalVisible: false)
        }
    }
}

/// Workspace Agent inspector: session navigation, streamed turns, tool approval/results,
/// queued prompts and the composer live in one compact surface.
struct AssistantView: View {
    /// 当前活动服务器的简述，进 system prompt（无则空串）。
    let serverContext: String
    /// meta 行展示的服务器短名（无则只显示「当前会话」）。
    var serverName: String = ""
    @Bindable var model: AssistantModel
    @Binding var activeProviderIDString: String
    /// 一次最多挂载多少条消息（`AgentMessageWindow`）。会话数据不受影响；
    /// 探针把它调成 `Int.max` 就是改前的「全量挂载」臂。
    var messageWindowLimit: Int = AgentMessageWindow.defaultLimit

    @Environment(\.openWindow) private var openWindow
    @Environment(\.modelContext) private var modelContext
    // 会话历史下拉只列最近 `ChatSessionQueries.recentLimit` 条（原来无 fetchLimit，
    // 一开窗就把库里全部会话物化出来）。
    @Query(ChatSessionQueries.recent) private var sessions: [ChatSession]

    @AppStorage("agentSafety") private var agentSafetyRaw = AgentSafety.readAuto.rawValue
    private var safetyBinding: Binding<AgentSafety> {
        Binding(get: { AgentSafety(rawValue: agentSafetyRaw) ?? .readAuto },
                set: { agentSafetyRaw = $0.rawValue })
    }

    @State private var showSessions = false
    @State private var followsChatTail = true
    @State private var pendingTailScroll: DispatchWorkItem?
    /// 用户点开「显示更早」后放大的上限；`nil` 表示仍用 `messageWindowLimit`。
    @State private var expandedWindowLimit: Int?

    var body: some View {
        Group {
            if model.providers.isEmpty {
                emptyState
            } else {
                ZStack(alignment: .top) {
                    VStack(spacing: 0) {
                        header
                        chat
                    }
                    if showSessions {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { showSessions = false }
                        sessionsDropdown
                            .padding(.top, AssistantHeaderLayout.dropdownTopInset)
                            .padding(.horizontal, 12)
                    }
                }
                .background(commandReturnShortcut)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            model.approvalMode = safetyBinding.wrappedValue
            model.attach(context: modelContext)
        }
        .onChange(of: agentSafetyRaw) { _, _ in model.approvalMode = safetyBinding.wrappedValue }
    }

    // MARK: - 顶栏

    var header: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(UD.accentTint)
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(UD.accent)
            }
            .frame(width: 28, height: 28)

            Button {
                showSessions.toggle()
            } label: {
                HStack(spacing: 5) {
                    Text(model.sessionTitle)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(UD.text)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(UD.text4)
                        .rotationEffect(.degrees(showSessions ? 180 : 0))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("会话历史")
            .help("会话历史")

            Button {
                model.startNewSession()
                showSessions = false
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(UD.text2)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 7).fill(UD.uw04))
                    .contentShape(RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("新建对话")
            .help("新建对话")
        }
        .padding(.horizontal, 10)
        .modifier(WorkspacePaneHeader())
        .background(UD.panel)
    }

    // MARK: - 会话历史下拉

    private var sessionsDropdown: some View {
        VStack(spacing: 0) {
            Text("会话历史")
                .font(.system(size: 10.5))
                .tracking(0.5)
                .foregroundStyle(UD.text4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .padding(.bottom, 4)
                .accessibilityAddTraits(.isHeader)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(UD.border).frame(height: 1)
                }

            if sessions.isEmpty {
                Text("还没有历史会话")
                    .font(.system(size: 11.5))
                    .foregroundStyle(UD.text4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(sessions) { sessionRow($0) }
                    }
                    .padding(4)
                }
                .frame(maxHeight: 280)
            }

            Button {
                model.startNewSession()
                showSessions = false
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "plus").font(.system(size: 11))
                    Text("新建对话").font(.system(size: 12))
                    Spacer()
                }
                .foregroundStyle(UD.text2)
                .padding(.vertical, 9)
                .padding(.horizontal, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(alignment: .top) {
                Rectangle().fill(UD.border).frame(height: 1)
            }
        }
        // 浮层：实体浮层底 + 1px 细边 + 阴影（v2 保留描边的「浮层边缘」情形）。
        .background(UD.overlay)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(UD.border, lineWidth: 1))
        .shadow(color: UD.dyn(.black(0.55), .black(0.18)), radius: 18, x: 0, y: 14)
    }

    private func sessionRow(_ s: ChatSession) -> some View {
        let isActive = s.id == model.currentSession?.id
        return Button {
            model.load(s)
            showSessions = false
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(s.title.isEmpty ? "新对话" : s.title)
                        .font(.system(size: 12.5, weight: isActive ? .medium : .regular))
                        .foregroundStyle(isActive ? UD.text : UD.text2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(UFormat.relative(s.updatedAt))
                        .font(.system(size: 10))
                        .foregroundStyle(UD.text3)
                }
                if !s.preview.isEmpty {
                    Text(s.preview)
                        .font(.system(size: 11))
                        .foregroundStyle(UD.text3)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? UD.accentSoft : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
        .contextMenu {
            Button("删除", role: .destructive) { delete(s) }
        }
    }

    private func delete(_ s: ChatSession) {
        if s.id == model.currentSession?.id { model.startNewSession() }
        modelContext.delete(s)
        try? modelContext.save()
    }

    // MARK: - 空状态

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.largeTitle).foregroundStyle(UD.text3)
            Text("还没添加 AI Provider")
                .font(.headline).foregroundStyle(UD.text)
            Text("在 Settings 添加一个 Anthropic / OpenAI 配置。")
                .font(.caption).foregroundStyle(UD.text3)
                .multilineTextAlignment(.center)
            UDButton(title: "打开 Settings", systemImage: "gearshape") {
                openWindow(id: SettingsWindow.id)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 聊天区

    private var chat: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if model.messages.isEmpty {
                            conversationEmptyState
                        } else {
                            earlierMessagesButton
                            // 行边界截断对齐参考线的递归查询（见 `AlignmentBarrier`）。
                            ForEach(mountedMessages) { message in
                                AlignmentBarrier { messageRow(message) }
                            }
                        }
                        // 底部留白由锚点自己承担：`scrollTo(_, anchor: .bottom)` 对齐的是锚点
                        // 底边，锚点下面再垫 padding 就永远差这一截滚不到底。
                        Color.clear.frame(height: 10).id(Self.bottomAnchorID)
                    }
                    // 滚动期间关掉气泡 hover（悬停铅笔 + tooltip）。
                    // 见 `UAppKitBridge/ScrollHoverGate.swift`。
                    .scrollHoverGate()
                    .padding(EdgeInsets(top: 16, leading: 14, bottom: 0, trailing: 14))
                }
                .defaultScrollAnchor(.bottom)
                // `.bottom` 同时会把短于视口的聊天内容贴到容器底部，形成顶部大块
                // 空白。只覆盖短内容的 alignment 角色；长会话的初始位置与内容增长
                // 仍沿用上面的 bottom anchor。
                .defaultScrollAnchor(.top, for: .alignment)
                .onScrollPhaseChange { _, phase, context in
                    if phase == .tracking || phase == .interacting {
                        followsChatTail = false
                        pendingTailScroll?.cancel()
                        pendingTailScroll = nil
                    }
                    if phase == .idle {
                        followsChatTail = AgentScrollPolicy.isNearBottom(
                            visibleMaxY: context.geometry.visibleRect.maxY,
                            contentHeight: context.geometry.contentSize.height)
                    }
                }
                // 贴底跟随听布局、不听消息模型：新消息、流式 Markdown 重排、工具卡展开、
                // 排队条带把视口挤矮，最终都只体现为「可滚高度变大」（见
                // `AgentScrollPolicy.needsRepin`）。只比一个 CGFloat + Bool，开销比原先的
                // 尾部签名（尾消息 id / 正文长度 / 工具卡数组）还小。
                .onScrollGeometryChange(for: AgentScrollPolicy.TailGeometry.self) { geometry in
                    AgentScrollPolicy.TailGeometry(
                        contentHeight: geometry.contentSize.height,
                        containerHeight: geometry.containerSize.height,
                        visibleMaxY: geometry.visibleRect.maxY)
                } action: { old, new in
                    if AgentScrollPolicy.needsRepin(from: old, to: new) {
                        scheduleScrollToBottom(proxy)
                    }
                }
                // 换会话（含「新对话」）时把渲染窗口收回默认值，
                // 否则上一段会话点开的「显示更早」会带进下一段。
                .onChange(of: model.messages.first?.id) { _, _ in
                    expandedWindowLimit = nil
                }
                .onChange(of: model.state) { old, now in
                    if old == .streaming && now != .streaming {
                        AccessibilityNotification.Announcement("回答已完成").post()
                    }
                }
                .onDisappear {
                    pendingTailScroll?.cancel()
                    pendingTailScroll = nil
                }
            }
            AgentQueueStrip(model: model,
                            insets: EdgeInsets(top: 6, leading: 10, bottom: 0, trailing: 10))
            inputBar
        }
    }

    private static let starterPrompts = [
        "检查服务器健康状态",
        "分析最近的错误日志",
        "给出当前服务的排查步骤",
    ]

    private var conversationEmptyState: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(UD.accentTint)
                    Image(systemName: "sparkles")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(UD.accent)
                }
                .frame(width: 42, height: 42)

                Text("让 Agent 接手下一步")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(UD.text)
                Text("描述目标即可。Agent 会结合当前服务器上下文分析问题，按所选档位审批命令，敏感操作仍需你确认。")
                    .font(.system(size: 12.5))
                    .lineSpacing(3)
                    .foregroundStyle(UD.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                capabilityLabel("读上下文", systemImage: "doc.text.magnifyingglass")
                capabilityLabel("工具审批", systemImage: "hand.raised")
                capabilityLabel("持续追问", systemImage: "arrow.trianglehead.2.clockwise")
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("可以从这里开始")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(UD.text4)
                ForEach(Self.starterPrompts, id: \.self) { prompt in
                    Button { model.input = prompt } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(UD.accent)
                            Text(prompt)
                                .font(.system(size: 12))
                                .foregroundStyle(UD.text2)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                        .background(RoundedRectangle(cornerRadius: 8).fill(UD.uw03))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
    }

    private func capabilityLabel(_ title: String, systemImage: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 11))
                .foregroundStyle(UD.text3)
            Text(title)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(UD.text3)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private static let bottomAnchorID = "assistant.bottom"

    private func scheduleScrollToBottom(_ proxy: ScrollViewProxy) {
        guard followsChatTail, pendingTailScroll == nil else { return }
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                pendingTailScroll = nil
                proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
            }
        }
        pendingTailScroll = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + AgentScrollPolicy.coalescingDelay,
            execute: work)
    }

    // MARK: - 渲染窗口

    /// 当前生效的挂载上限：用户点过「显示更早」就用放大后的值。
    private var effectiveWindowLimit: Int {
        max(expandedWindowLimit ?? messageWindowLimit, 1)
    }

    /// 真正挂进视图树的那一段。整段消息仍完整留在 `model.messages` /
    /// SwiftData / 模型上下文里，这里只是不把它们全建成视图。
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

    @ViewBuilder
    private func messageRow(_ message: ChatMessage) -> some View {
        if message.role == .user {
            UserMessageRow(
                message: message,
                isEditing: model.editingMessageID == message.id,
                canEdit: !model.isBusy,
                onBeginEdit: { model.editingMessageID = message.id },
                onCancel: { model.editingMessageID = nil },
                onCommit: { newText in
                    Task {
                        await model.editAndResend(id: message.id, newText: newText,
                                                  serverContext: serverContext)
                    }
                }
            )
            .id(message.id)
        } else {
            assistantMessageRow(message)
        }
    }

    @ViewBuilder
    private func assistantMessageRow(_ message: ChatMessage) -> some View {
        let isStreamingTail = message.id == model.messages.last?.id
            && model.state == .streaming
        VStack(alignment: .leading, spacing: 10) {
            // 空文本的已结算消息可能只承载工具卡；不要把它误画成仍在等待的“…”。
            // 真正的流式空消息显示「思考中」流光，收到正文后再挂载 Markdown。
            //
            // 正文不放进 HStack（「头像｜正文」「正文｜光标」）：HStack 回答任何排版问题前都要
            // 按伸缩优先级把弹性子视图在几种宽度下各量一遍，正文是整棵 Markdown，每量一次
            // 就重排一遍文字，流式时尾消息每批都来一轮。头像改成左缩进 + 叠层，光标叠在
            // 正文末尾外侧。实测挂满 1000 条时流式主线程心跳 610 → 943/1500。
            if !message.text.isEmpty || isStreamingTail {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Agent")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(UD.text3)
                    if message.text.isEmpty {
                        AgentThinkingIndicator()
                    } else {
                        AlignmentBarrier {
                            StreamingMarkdownView(text: message.text, isStreaming: isStreamingTail)
                                .textSelection(.enabled)
                        }
                        .overlay(alignment: .bottomTrailing) {
                            if isStreamingTail {
                                StreamingCaret()
                                    .alignmentGuide(.trailing) { $0[.leading] - 3 }
                                    .padding(.bottom, 2)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 33)
                .overlay(alignment: .topLeading) { agentAvatar }
            }

            ForEach(message.toolCalls) { call in
                AgentToolCallCard(
                    call: call,
                    approvalEnabled: model.state == .awaitingApproval,
                    isReviewing: model.reviewingToolCallID == call.id,
                    onRun: { Task { await model.approveAndRun(id: call.id) } },
                    onSkip: { Task { await model.skip(id: call.id) } }
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .id(message.id)
    }

    private var agentAvatar: some View {
        Image(systemName: "sparkles")
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(UD.accent)
            .frame(width: 24, height: 24)
            .background(RoundedRectangle(cornerRadius: 7).fill(UD.accentTint))
    }

    private func firstPendingToolCallID() -> String? {
        for message in model.messages {
            if let call = message.toolCalls.first(where: { $0.status == .pending }) {
                return call.id
            }
        }
        return nil
    }

    // MARK: - 输入区

    private var inputBar: some View {
        AgentComposer(
            model: model,
            placeholder: "描述目标，交给 Agent 处理…",
            minLines: 2,
            safety: safetyBinding,
            activeProviderIDString: $activeProviderIDString,
            onSend: sendIfPossible,
            onAttach: attachCurrentContext,
            onOpenSettings: { openWindow(id: SettingsWindow.id) })
            .padding(10)
    }

    private func sendIfPossible() {
        // 同步清空输入再异步发送，避免回车后「先全选再发」的一帧闪烁（与终端 Agent 一致）。
        let text = model.input
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        model.input = ""
        Task { await model.submit(text: text, serverContext: serverContext) }
    }

    /// 工作区 Agent 与终端 Agent 共用同一条 ⌘↵ 语义：待确认时优先运行命令，
    /// 否则发送当前输入。
    private func handleCommandReturn() {
        if model.state == .awaitingApproval, let id = firstPendingToolCallID() {
            Task { await model.approveAndRun(id: id) }
        } else {
            sendIfPossible()
        }
    }

    /// `UDToolCall` 只展示「⌘↵」提示；由容器统一注册真实快捷键，避免多张命令卡重复绑定。
    private var commandReturnShortcut: some View {
        Button("", action: handleCommandReturn)
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(.plain)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }

    private func attachCurrentContext() {
        let snippet = currentContextSnippet()
        guard !snippet.isEmpty else { return }
        if model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            model.input = snippet
        } else {
            model.input += "\n\n\(snippet)"
        }
    }

    private func currentContextSnippet() -> String {
        let context = serverContext.trimmingCharacters(in: .whitespacesAndNewlines)
        if !context.isEmpty {
            return "上下文：\n\(context)"
        }
        let name = serverName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "" : "当前服务器：\(name)"
    }
}

/// A compact execution trace for one Agent tool call. It keeps command approval, progress,
/// result disclosure, exit status, and copying in the conversation instead of a separate modal.
private struct AgentToolCallCard: View {
    let call: ToolCallState
    let approvalEnabled: Bool
    /// AI 审批进行中（仍可手动运行或跳过）。
    let isReviewing: Bool
    let onRun: () -> Void
    let onSkip: () -> Void

    @State private var isResultExpanded = false
    @State private var isCommandCopied = false
    /// 命令行整行一个 `onHover`，只用来门控 tooltip（见 `HoverGatedHelp`）。
    @State private var isHoveringCommandRow = false

    private var presentation: AgentToolCallPresentation {
        AgentToolCallPresentation.resolve(call)
    }

    private var toneColor: Color {
        switch presentation.tone {
        case .accent: return UD.accent
        case .success: return UD.success
        case .warning: return UD.warning
        case .danger: return UD.danger
        case .muted: return UD.text3
        }
    }

    private var displayTitle: String {
        let explanation = call.explanation?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return explanation.isEmpty ? "运行 Shell 命令" : explanation
    }

    private var toolLabel: String {
        call.name == "run_command" ? "Shell" : call.name
    }

    private var hasResult: Bool {
        guard let output = call.output else { return false }
        return !output.isEmpty
    }

    /// 执行中 / 已完成 / 已跳过收成一行；只有要人处理的（待确认、执行失败）用完整卡片。
    private var isCompact: Bool {
        call.status == .running || call.status == .done || call.status == .skipped
    }

    /// 待确认、失败用状态描边（设计语言 v2 白名单）；其余是中性细线。
    private var cardStroke: Color {
        switch call.status {
        case .pending: return UD.warning.opacity(0.45)
        case .failed: return UD.danger.opacity(0.4)
        default: return UD.border
        }
    }

    var body: some View {
        Group {
            if isCompact {
                compactRow
            } else {
                fullCard
            }
        }
        .onAppear {
            if call.status == .failed { isResultExpanded = true }
        }
        .onChange(of: call.status) { _, status in
            if status == .failed { isResultExpanded = true }
        }
    }

    private var fullCard: some View {
        VStack(spacing: 0) {
            header
            commandRow
            if hasResult {
                resultDisclosure
            }
            if presentation.isApprovalVisible {
                actionFooter
            }
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(UD.card))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(cardStroke, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: 紧凑行

    /// 怎么放行的：规则放行的只读命令、AI 代批。人工点的运行不标。
    private var autoApprovalTag: String? {
        guard call.approvalReason != nil else { return nil }
        switch call.approvedByAI {
        case nil: return "只读 · 自动"
        case true?: return "AI 已批准"
        case false?: return nil
        }
    }

    private var compactRow: some View {
        VStack(spacing: 0) {
            // 没有输出时点了什么也不做；不用 `.disabled`，它会把整行文字压灰。
            Button {
                guard hasResult else { return }
                withAnimation(.easeInOut(duration: 0.16)) { isResultExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    compactGlyph
                        .frame(width: 14, height: 14)
                    Text(call.command.isEmpty ? displayTitle : call.command)
                        .font(UD.mono(11))
                        .foregroundStyle(call.status == .skipped ? UD.text4 : UD.text2)
                        .strikethrough(call.status == .skipped, color: UD.text4)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let tag = autoApprovalTag {
                        Text(tag)
                            .font(.system(size: 9.5))
                            .foregroundStyle(UD.text4)
                            .fixedSize()
                    }
                    if let exitCode = call.exitCode, exitCode != 0 {
                        Text("exit \(exitCode)")
                            .font(UD.mono(9.5))
                            .foregroundStyle(UD.danger)
                            .fixedSize()
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(UD.text4)
                        .rotationEffect(.degrees(isResultExpanded ? 180 : 0))
                        .opacity(hasResult ? 1 : 0)
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("复制命令", action: copyCommand)
                    .disabled(call.command.isEmpty)
            }
            .accessibilityLabel(compactAccessibilityLabel)

            if isResultExpanded, let output = call.output {
                VStack(alignment: .leading, spacing: 6) {
                    if let explanation = call.explanation, !explanation.isEmpty {
                        Text(explanation)
                            .font(.system(size: 10.5))
                            .foregroundStyle(UD.text3)
                    }
                    outputText(output)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(UD.termBg)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(UD.uw03))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private var compactGlyph: some View {
        switch call.status {
        case .running:
            SpinningArc(color: UD.accent, size: 11, lineWidth: 1.5, trim: 0.3, duration: 0.9)
        case .skipped:
            Image(systemName: "forward.end.fill")
                .font(.system(size: 9))
                .foregroundStyle(UD.text4)
        default:
            let failed = (call.exitCode ?? 0) != 0
            Image(systemName: failed ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(failed ? UD.danger : UD.success)
        }
    }

    private var compactAccessibilityLabel: String {
        var parts = [presentation.title, call.command]
        if let tag = autoApprovalTag { parts.append(tag) }
        return parts.joined(separator: "，")
    }

    // MARK: 完整卡片

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "terminal")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(toneColor)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(toneColor.opacity(0.12)))

            VStack(alignment: .leading, spacing: 2) {
                Text(displayTitle)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(UD.text)
                    .lineLimit(2)
                Text("工具 · \(toolLabel)")
                    .font(.system(size: 9.5))
                    .foregroundStyle(UD.text4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 5) {
                if presentation.isProgressVisible {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.68)
                        .frame(width: 11, height: 11)
                } else {
                    Image(systemName: presentation.systemImage)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(toneColor)
                }
                Text(presentation.title)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(toneColor)
            }
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(Capsule().fill(toneColor.opacity(0.11)))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }

    private var commandRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("$")
                .foregroundStyle(UD.accent)
            Text(call.command.isEmpty ? "正在接收工具参数…" : call.command)
                .foregroundStyle(call.command.isEmpty ? UD.text4 : UD.text2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Button(action: copyCommand) {
                Image(systemName: isCommandCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(isCommandCopied ? UD.success : UD.text3)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 6).fill(UD.uw04))
                    .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .disabled(call.command.isEmpty)
            .accessibilityLabel(isCommandCopied ? "命令已复制" : "复制命令")
            .help(whenHovering: isHoveringCommandRow, isCommandCopied ? "已复制" : "复制命令")
        }
        .font(UD.mono(11))
        .padding(.leading, 11)
        .padding(.trailing, 8)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hoverGated { isHoveringCommandRow = $0 }
        .background(UD.termBg)
        .overlay(alignment: .top) { Rectangle().fill(UD.border).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(UD.border).frame(height: 1) }
    }

    private var resultDisclosure: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    isResultExpanded.toggle()
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 9.5))
                    Text(call.status == .failed ? "错误输出" : "工具输出")
                        .font(.system(size: 10.5, weight: .medium))
                    if let exitCode = call.exitCode {
                        Text("exit \(exitCode)")
                            .font(UD.mono(9.5))
                            .foregroundStyle(exitCode == 0 ? UD.text4 : UD.danger)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8.5, weight: .semibold))
                        .rotationEffect(.degrees(isResultExpanded ? 180 : 0))
                }
                .foregroundStyle(UD.text3)
                .padding(.horizontal, 10)
                .frame(height: 31)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isResultExpanded, let output = call.output {
                outputText(output)
                .padding(.horizontal, 10)
                .padding(.bottom, 9)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func outputText(_ output: String) -> some View {
        ScrollView {
            Text(output)
                .font(UD.mono(10.5))
                .foregroundStyle(call.status == .failed ? UD.danger : UD.text3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .frame(maxHeight: 140)
    }

    /// 待确认时底栏左侧那句话：AI 审批中 / 为什么要人确认 / 默认提示。
    private var approvalNote: (text: String, isWarning: Bool) {
        if isReviewing { return ("AI 正在审批，也可以直接运行或跳过", false) }
        if !approvalEnabled { return ("正在准备操作", false) }
        if call.approvedByAI == false, let reason = call.approvalReason { return (reason, true) }
        return ("需要你的确认", false)
    }

    /// 待确认卡片的底栏：上一行说明（为什么要你确认 / AI 审批中），下一行运行 / 跳过。
    private var actionFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if isReviewing {
                    SpinningArc(color: UD.accent, size: 9, lineWidth: 1.5, trim: 0.3, duration: 0.9)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                } else {
                    Image(systemName: approvalNote.isWarning ? "exclamationmark.shield.fill" : "hand.raised.fill")
                        .font(.system(size: 9.5))
                        .foregroundStyle(approvalNote.isWarning ? UD.warning : UD.text4)
                }
                Text(approvalNote.text)
                    .font(.system(size: 10.5))
                    .foregroundStyle(approvalNote.isWarning ? UD.text2 : UD.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 7) {
                // 设计语言 v2 主按钮：accent 14% 底 + accent 字。
                Button(action: onRun) {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill").font(.system(size: 8))
                        Text("运行").font(.system(size: 11, weight: .semibold))
                        Text("⌘↵").font(UD.mono(9.5)).opacity(0.7)
                    }
                    .foregroundStyle(approvalEnabled ? UD.accent : UD.text4)
                    .padding(.horizontal, 10)
                    .frame(height: 27)
                    .background(RoundedRectangle(cornerRadius: 7)
                        .fill(approvalEnabled ? UD.accentTint : UD.accentTintDisabled))
                    .contentShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .disabled(!approvalEnabled)

                Button(action: onSkip) {
                    Text("跳过")
                        .font(.system(size: 11))
                        .foregroundStyle(approvalEnabled ? UD.text3 : UD.text4)
                        .padding(.horizontal, 10)
                        .frame(height: 27)
                        .background(RoundedRectangle(cornerRadius: 7).fill(UD.uw04))
                        .contentShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .disabled(!approvalEnabled)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        // 紧跟命令行时由命令行的底线分隔，再画一条就成了双线；只有隔着输出区才补顶线。
        .overlay(alignment: .top) {
            if hasResult { Rectangle().fill(UD.border).frame(height: 1) }
        }
    }

    private func copyCommand() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(call.command, forType: .string)
        isCommandCopied = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            isCommandCopied = false
        }
    }
}

/// 等首个 token 时的占位：「思考中」上扫过一道流光，旁边是已等的秒数。
/// 流光走 CA（`ShimmerSweep`）；秒数每秒才刷一次，不会让整窗满帧重绘。
struct AgentThinkingIndicator: View {
    var fontSize: CGFloat = 12.5
    @State private var startedAt = Date()

    var body: some View {
        HStack(spacing: 6) {
            label
                .foregroundStyle(UD.text3)
                .overlay { ShimmerSweep(color: UD.text).mask { label } }
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                let seconds = Int(context.date.timeIntervalSince(startedAt))
                Text(seconds > 0 ? "\(seconds)s" : "")
                    .font(.system(size: fontSize - 1.5).monospacedDigit())
                    .foregroundStyle(UD.text4)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Agent 正在思考")
    }

    private var label: some View {
        Text("思考中").font(.system(size: fontSize, weight: .medium))
    }
}

/// 流式输出时的闪烁光标。
///
/// 闪烁走 CA（见 `CAMotion.swift`），不用 SwiftUI `.repeatForever` —— 后者会让
/// **整个窗口**在每次流式回答的全程满帧重绘，代价跟视图树大小成正比。
/// Reduce Motion 下常显不闪，由 `BlinkingBar` 内部处理。
private struct StreamingCaret: View {
    var body: some View {
        BlinkingBar(color: UD.accent, width: 4, height: 12,
                    cornerRadius: 1, minOpacity: 0.15, duration: 0.55)
    }
}

/// 用户消息气泡：常态展示 + 悬停露铅笔；编辑态原地变可编辑框 + ✓重发 / ✕取消。
private struct UserMessageRow: View {
    let message: ChatMessage
    let isEditing: Bool
    let canEdit: Bool
    let onBeginEdit: () -> Void
    let onCancel: () -> Void
    let onCommit: (String) -> Void

    @State private var draft: String = ""
    @State private var isHovering = false

    var body: some View {
        Group {
            if isEditing {
                editor
            } else {
                bubble
            }
        }
        .onChange(of: isEditing, initial: true) { _, now in
            if now { draft = message.text }
        }
    }

    /// 常态气泡：点击进入编辑（仅空闲可编辑）。不插入/移除任何子视图
    /// → 无布局抖动、无闪烁（去掉了旧的悬停铅笔钮）。
    private var bubble: some View {
        HStack(alignment: .top) {
            Spacer(minLength: 26)
            Text(message.text)
                .font(.system(size: 12.5))
                .lineSpacing(2)
                .foregroundStyle(UD.text)
                .textSelection(.enabled)
                .padding(.vertical, 10)
                .padding(.leading, 12)
                .padding(.trailing, canEdit ? 28 : 12)
                .background(UD.accentTint)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if canEdit {
                        Image(systemName: "pencil")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(UD.text3)
                            .frame(width: 24, height: 24)
                            .opacity(isHovering ? 1 : 0)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .onTapGesture { if canEdit { onBeginEdit() } }
                // 滚动期间不接 hover：消息流滚过指针时每条气泡都会亮一下铅笔
                // 并挂一次 tooltip（见 `UAppKitBridge/ScrollHoverGate.swift`）。
                .hoverGated { isHovering = $0 }
                // 悬停门控：行上本来就有 `isHovering`，不悬停的行不必给
                // `NSToolTipManager` 留一块每个滚动 tick 都要重算的区域。
                .help(whenHovering: isHovering && canEdit, "点击编辑并重发")
                // 悬停铅笔是纯装饰（`accessibilityHidden`），点击进编辑的能力
                // 全靠 `onTapGesture` —— 对 AX 完全不可见。显式补 label +
                // isButton + 默认动作 + 命名动作，读屏 / 全键盘控制才进得去编辑态。
                //
                // `accessibilityElement(children: .combine)` 不是可有可无的：
                // 实测只加 label / traits / action 而不合成元素时，AX 树里那个
                // 元素的 role 确实是 button，但 `accessibilityPerformPress()`
                // 返回 false —— 动作根本没挂上去。合成之后才真的能按
                // （`TapGestureRowAccessibilityTests.testUserBubbleIsAccessibleAndBeginsEditing`）。
                .accessibilityElement(children: .combine)
                .accessibilityLabel(message.text)
                .accessibilityAddTraits(canEdit ? .isButton : [])
                .accessibilityHint(canEdit ? "点按编辑并重发" : "")
                .accessibilityAction { if canEdit { onBeginEdit() } }
                .accessibilityAction(named: "编辑") { if canEdit { onBeginEdit() } }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .lineLimit(1...8)
                .foregroundStyle(UD.text)
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Button(action: onCancel) {
                    Text("✕").font(.system(size: 12)).foregroundStyle(UD.text3)
                        .frame(width: 26, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel("取消").help("取消")
                Button { onCommit(draft) } label: {
                    Text("✓").font(.system(size: 12)).foregroundStyle(UD.accent)
                        .frame(width: 26, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel("重发").help("重发（截断其后并重新生成）")
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(UD.inputBg)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(UD.border, lineWidth: 1))
    }
}
