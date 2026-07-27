import UDesignKit
import SwiftUI
import SwiftData

enum AssistantInputBarLayout {
    /// 底栏图标钮（附加 / 发送）点击区，对齐设计稿 28×28。
    nonisolated static let attachHitSize: CGFloat = 28
    nonisolated static let attachIconSize: CGFloat = 12
    nonisolated static let attachCornerRadius: CGFloat = 7
    /// 发送钮与附加钮同尺寸（28²），保持底栏对称。
    nonisolated static let sendButtonHeight: CGFloat = 28
    nonisolated static let keycapHeight: CGFloat = 20
    nonisolated static let sendContentAlignment: VerticalAlignment = .center
}

/// AI 助手聊天面板。布局对齐工作区设计稿（`workspace.jsx`）的 Agent inspector
/// 最终形态（Cursor 风格）：
/// - 顶栏：✦ + 会话标题（点开 → 会话历史下拉）+ 新建对话。
/// - 聊天区：对话直接平铺在标题下——用户气泡 / 助手裸文本 + 流式光标（无角色标签、无 meta 行）。
/// - 输入区：圆角卡片，底栏左侧模型胶囊 `● <模型> ▾`，右侧附件 + ↩ 发送（去掉上方分割线）。
///
/// 0 provider：空状态 + 「打开 Settings」按钮。
struct AssistantView: View {
    /// 当前活动服务器的简述，进 system prompt（无则空串）。
    let serverContext: String
    /// meta 行展示的服务器短名（无则只显示「当前会话」）。
    var serverName: String = ""
    @Bindable var model: AssistantModel
    @Binding var activeProviderIDString: String

    @Environment(\.openWindow) private var openWindow
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ChatSession.updatedAt, order: .reverse) private var sessions: [ChatSession]

    @State private var showSessions = false
    @State private var followsChatTail = true
    @State private var pendingTailScroll: DispatchWorkItem?

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
                            .padding(.top, 38)
                            .padding(.horizontal, 12)
                    }
                }
                .background(commandReturnShortcut)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { model.attach(context: modelContext) }
    }

    // MARK: - 顶栏

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 13))
                .foregroundStyle(UD.accent)

            Button {
                showSessions.toggle()
            } label: {
                HStack(spacing: 6) {
                    Text(model.sessionTitle)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(UD.text)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(UD.text3)
                        .rotationEffect(.degrees(showSessions ? 180 : 0))
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(showSessions ? UD.fillSoft : .clear))
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
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(UD.text3)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("新建对话")
            .help("新建对话")
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: 36)
        .overlay(alignment: .bottom) {
            Rectangle().fill(UD.border).frame(height: 1)
        }
    }

    // MARK: - 模型选择胶囊（输入区底栏，Cursor 风格 ● <模型> ▾）

    /// 底栏模型胶囊：原 meta 行的 provider 选择器，移到输入框页脚（设计稿 chat8）。
    private var modelPill: some View {
        Menu {
            ForEach(model.providers) { p in
                Button {
                    activeProviderIDString = p.id.uuidString
                } label: {
                    let label = p.model.isEmpty ? p.name : "\(p.name) · \(p.model)"
                    if p.id == model.activeProvider?.id {
                        Label(label, systemImage: "checkmark")
                    } else {
                        Text(label)
                    }
                }
            }
            Divider()
            Button("管理…") { openWindow(id: SettingsWindow.id) }
        } label: {
            UDModelPillLabel(modelPillLabel)
        }
        // .button + plain 渲染完整自定义 label（含蓝点 + 末尾 ▾ + 描边胶囊）；
        // .borderlessButton 会把自定义 label 压扁成纯文本 + 前置系统箭头。
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// 胶囊文案：优先显示模型名（如 `claude-sonnet`），否则 provider 名；过长则省略。
    private var modelPillLabel: String {
        let raw: String
        if let p = model.activeProvider {
            raw = p.model.isEmpty ? p.name : p.model
        } else {
            raw = "未选择"
        }
        return raw.count > 22 ? String(raw.prefix(21)) + "…" : raw
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
                    VStack(spacing: 2) {
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
                    Text(relativeTime(s.updatedAt))
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

    private func relativeTime(_ date: Date) -> String {
        let now = Date()
        let cal = Calendar.current
        if now.timeIntervalSince(date) < 60 { return "刚刚" }
        if cal.isDateInToday(date) {
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            return "今天 \(f.string(from: date))"
        }
        if cal.isDateInYesterday(date) { return "昨天" }
        let days = cal.dateComponents([.day],
                                      from: cal.startOfDay(for: date),
                                      to: cal.startOfDay(for: now)).day ?? 0
        if days < 7 { return "\(days) 天前" }
        let f = DateFormatter(); f.dateFormat = "M/d"
        return f.string(from: date)
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
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(model.messages) { messageRow($0) }
                        Color.clear.frame(height: 1).id(Self.bottomAnchorID)
                    }
                    .padding(EdgeInsets(top: 14, leading: 14, bottom: 8, trailing: 14))
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
                .onChange(of: model.messages.last?.text) { _, _ in
                    scheduleScrollToBottom(proxy)
                }
                .onChange(of: model.messages.last?.id) { _, _ in
                    scheduleScrollToBottom(proxy)
                }
                .onChange(of: model.state) { old, now in
                    scheduleScrollToBottom(proxy)
                    // 流式落定时给 VoiceOver 播报，无需用户盯着屏幕。
                    if old == .streaming && now != .streaming {
                        AccessibilityNotification.Announcement("回答已完成").post()
                    }
                }
                .onDisappear {
                    pendingTailScroll?.cancel()
                    pendingTailScroll = nil
                }
            }
            queueStrip
            inputBar
        }
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
        VStack(alignment: .leading, spacing: 6) {
            // MarkdownBlocks 的根是多层 VStack。对它请求 firstTextBaseline 会递归遍历
            // 整棵 Markdown 布局树；长流式回复会在 AttributeGraph 中形成极深的
            // explicitAlignment/sizeThatFits 热点。顶部对齐不需要递归基线测量。
            // 空文本的已结算消息可能只承载工具卡；不要把它误画成仍在等待的“…”。
            // 真正的流式空消息只显示闪烁光标，收到正文后再挂载 Markdown。
            if !message.text.isEmpty || isStreamingTail {
                HStack(alignment: .top, spacing: 2) {
                    if !message.text.isEmpty {
                        StreamingMarkdownView(text: message.text, isStreaming: isStreamingTail)
                            .textSelection(.enabled)
                    }
                    if isStreamingTail {
                        StreamingCaret()
                            .padding(.top, 3)
                            .accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            ForEach(message.toolCalls) { call in
                UDToolCall(
                    label: call.explanation ?? "运行命令",
                    command: call.command,
                    status: udStatus(call),
                    // 仅在状态机真正进入「待批准」时才允许点运行/跳过；流式（卡片可能
                    // 已渲染成 pending）期间禁用，避免在流未结束时触发状态机重入。
                    approvalEnabled: model.state == .awaitingApproval,
                    onRun: { Task { await model.approveAndRun(id: call.id) } },
                    onSkip: { Task { await model.skip(id: call.id) } }
                )
            }
        }
        .id(message.id)
    }

    private func udStatus(_ call: ToolCallState) -> UDToolCall.Status {
        switch call.status {
        case .pending: return .pending
        case .running: return .running
        case .done, .failed, .skipped: return .done(output: call.output)
        }
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

    /// 待发队列条带：聊天区与输入框之间，列出尚未发出的排队消息（Agent 忙碌时累积）。
    @ViewBuilder
    private var queueStrip: some View {
        if !model.queuedMessages.isEmpty {
            VStack(spacing: 4) {
                ForEach(model.queuedMessages) { queuedRow($0) }
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
        }
    }

    private func queuedRow(_ item: QueuedMessage) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "clock")
                .font(.system(size: 10))
                .foregroundStyle(UD.text4)
            Text(item.text)
                .font(.system(size: 12))
                .foregroundStyle(UD.text3)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { model.loadQueuedForEditing(id: item.id) } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 10)).foregroundStyle(UD.text4)
                    .frame(width: 20, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("编辑").help("编辑")
            Button { model.removeQueued(id: item.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10)).foregroundStyle(UD.text4)
                    .frame(width: 20, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("移除").help("移除")
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(UD.fillSoft))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(UD.border, style: StrokeStyle(lineWidth: 1, dash: [3]))
        )
        .contentShape(Rectangle())
        .onTapGesture { model.loadQueuedForEditing(id: item.id) }
    }

    private var inputBar: some View {
        UDComposer(
            text: $model.input,
            queueing: model.isBusy,
            onSend: sendIfPossible,
            onAttach: attachCurrentContext,
            modelControl: { modelPill }
        )
        .clipShape(RoundedRectangle(cornerRadius: UD.Radius.lg, style: .continuous))
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

/// 流式输出时的闪烁光标。
private struct StreamingCaret: View {
    @State private var on = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(UD.accent)
            .frame(width: 4, height: 12)
            // Reduce Motion：停掉闪烁，光标常显（瞬时态）。
            .opacity(reduceMotion ? 1 : (on ? 1 : 0.15))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                    on = false
                }
            }
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
        Text(message.text)
            .font(.system(size: 12.5))
            .lineSpacing(2)
            .foregroundStyle(UD.text2)
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(UD.inputBg)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(UD.border, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 9))
            .onTapGesture { if canEdit { onBeginEdit() } }
            .help(canEdit ? "点击编辑并重发" : "")
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
