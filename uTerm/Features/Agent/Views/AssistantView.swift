import AgentKit
import AppKit
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

/// Agent 顶栏几何。高度与文件浏览器路径栏（`FileBrowserContent.header`）、编辑器
/// tab 栏（`PreviewTabBar`）、终端 tab 栏（`TerminalTabBar`）统一为 36，让工作区
/// 三栏顶部落在同一条基线上。
enum AssistantHeaderLayout {
    nonisolated static let height: CGFloat = 36
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
/// contextual follow-ups, queued prompts, and the composer live in one compact surface.
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
    @Query(sort: \ChatSession.updatedAt, order: .reverse) private var sessions: [ChatSession]

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
        .onAppear { model.attach(context: modelContext) }
    }

    // MARK: - 顶栏

    private var header: some View {
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
        // 与左侧文件浏览器路径栏 / 编辑器 tab 栏同高（36），三条顶栏在一条水平线上。
        .frame(height: AssistantHeaderLayout.height)
        .background(UD.panel)
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
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if model.messages.isEmpty {
                            conversationEmptyState
                        } else {
                            earlierMessagesButton
                            ForEach(mountedMessages) { messageRow($0) }
                            if model.messages.last?.role == .assistant {
                                followUpsView
                            }
                        }
                        Color.clear.frame(height: 1).id(Self.bottomAnchorID)
                    }
                    .padding(EdgeInsets(top: 16, leading: 14, bottom: 10, trailing: 14))
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
                // 尾部签名：把「尾消息 id / 正文长度 / 工具卡状态 / 追问」四路变化
                // 合成一个 Equatable 值，一个 onChange 顶掉原来的五个。原先每个
                // onChange 都在 ScrollView 上挂一个 AttributeGraph 节点、各存一份
                // 旧值（其中 toolCalls 还是数组），而它们的动作完全相同。
                .onChange(of: ChatTailSignature(model)) { _, _ in
                    scheduleScrollToBottom(proxy)
                }
                // 换会话（含「新对话」）时把渲染窗口收回默认值，
                // 否则上一段会话点开的「显示更早」会带进下一段。
                .onChange(of: model.messages.first?.id) { _, _ in
                    expandedWindowLimit = nil
                }
                .onChange(of: model.state) { old, now in
                    scheduleScrollToBottom(proxy)
                    if old == .streaming && now != .streaming {
                        AccessibilityNotification.Announcement("回答已完成").post()
                    }
                    let wasActive = old == .streaming || old == .running
                    let isSettled = now == .idle || now == .awaitingApproval
                    if wasActive, isSettled, model.messages.last?.role == .assistant {
                        model.refreshFollowUps(serverContext: serverContext)
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
                Text("描述目标即可。Agent 会结合当前服务器上下文分析问题，并在运行命令前等待你的确认。")
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

    @ViewBuilder
    private var followUpsView: some View {
        if model.state != .streaming, model.state != .running {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(UD.accent)
                    Text("下一步")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(UD.text4)
                    Spacer(minLength: 8)
                    Button { model.refreshFollowUps(serverContext: serverContext) } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(UD.text3)
                            .frame(width: 22, height: 22)
                            .background(RoundedRectangle(cornerRadius: 6).fill(UD.uw03))
                    }
                    .buttonStyle(.plain)
                    .disabled(model.followUpsLoading)
                    .help("换一批建议")
                }

                if model.followUpsLoading {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text("正在生成建议")
                            .font(.system(size: 11.5))
                            .foregroundStyle(UD.text3)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                } else {
                    ForEach(model.followUps, id: \.self) { suggestion in
                        Button { model.input = suggestion } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(UD.accent)
                                Text(suggestion)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(UD.text2)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 31)
                            .background(RoundedRectangle(cornerRadius: 8).fill(UD.uw03))
                            .contentShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onAppear {
                if (model.state == .idle || model.state == .awaitingApproval),
                   model.followUps.isEmpty, !model.followUpsLoading {
                    model.refreshFollowUps(serverContext: serverContext)
                }
            }
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
            // MarkdownBlocks 的根是多层 VStack。对它请求 firstTextBaseline 会递归遍历
            // 整棵 Markdown 布局树；长流式回复会在 AttributeGraph 中形成极深的
            // explicitAlignment/sizeThatFits 热点。顶部对齐不需要递归基线测量。
            // 空文本的已结算消息可能只承载工具卡；不要把它误画成仍在等待的“…”。
            // 真正的流式空消息只显示闪烁光标，收到正文后再挂载 Markdown。
            if !message.text.isEmpty || isStreamingTail {
                HStack(alignment: .top, spacing: 9) {
                    agentAvatar
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text("Agent")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(UD.text3)
                            if isStreamingTail {
                                Text("正在处理")
                                    .font(.system(size: 9.5, weight: .medium))
                                    .foregroundStyle(UD.accent)
                                    .padding(.horizontal, 6)
                                    .frame(height: 18)
                                    .background(Capsule().fill(UD.accentTint))
                            }
                        }
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
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            ForEach(message.toolCalls) { call in
                AgentToolCallCard(
                    call: call,
                    approvalEnabled: model.state == .awaitingApproval,
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
            placeholder: "描述目标，Agent 会分析并在使用工具前请求确认…",
            minLines: 2,
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

/// A compact execution trace for one Agent tool call. It keeps command approval, progress,
/// result disclosure, exit status, and copying in the conversation instead of a separate modal.
/// 「贴底跟随」要监听的四路变化压成一个 Equatable 值：尾消息身份、正文长度、
/// 尾消息的工具卡、追问。正文用 `utf8.count`（原生 Swift 字符串是 O(1)）而不是
/// 整串——流式期间正文只增不减，长度就是忠实的变化指纹，也省掉每次 body 求值
/// 都把一份长文本存进 onChange 的旧值里。
private struct ChatTailSignature: Equatable {
    let lastID: UUID?
    let lastTextLength: Int
    let toolCalls: [ToolCallState]
    let followUps: [String]
    let followUpsLoading: Bool

    @MainActor
    init(_ model: AssistantModel) {
        let last = model.messages.last
        lastID = last?.id
        lastTextLength = last?.text.utf8.count ?? 0
        toolCalls = last?.toolCalls ?? []
        followUps = model.followUps
        followUpsLoading = model.followUpsLoading
    }
}

private struct AgentToolCallCard: View {
    let call: ToolCallState
    let approvalEnabled: Bool
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

    var body: some View {
        VStack(spacing: 0) {
            header
            commandRow
            if hasResult {
                resultDisclosure
            }
            if presentation.isApprovalVisible || presentation.isProgressVisible {
                actionFooter
            }
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(UD.card))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(UD.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onAppear {
            if call.status == .failed { isResultExpanded = true }
        }
        .onChange(of: call.status) { _, status in
            if status == .failed { isResultExpanded = true }
        }
    }

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
        .onHover { isHoveringCommandRow = $0 }
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
                ScrollView {
                    Text(output)
                        .font(UD.mono(10.5))
                        .foregroundStyle(call.status == .failed ? UD.danger : UD.text3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 140)
                .padding(.horizontal, 10)
                .padding(.bottom, 9)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    @ViewBuilder
    private var actionFooter: some View {
        if presentation.isProgressVisible {
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text("命令正在远端执行")
                    .font(.system(size: 10.5))
                    .foregroundStyle(UD.text3)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .overlay(alignment: .top) { Rectangle().fill(UD.border).frame(height: 1) }
        } else {
            HStack(spacing: 7) {
                Button(action: onRun) {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill").font(.system(size: 8))
                        Text("运行").font(.system(size: 11, weight: .semibold))
                        Text("⌘↵").font(UD.mono(9.5)).foregroundStyle(UD.text3)
                    }
                    .foregroundStyle(approvalEnabled ? UD.text : UD.text4)
                    .padding(.horizontal, 10)
                    .frame(height: 27)
                    .background(RoundedRectangle(cornerRadius: 7).fill(UD.accentTint))
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

                Spacer(minLength: 0)
                Text(approvalEnabled ? "需要你的确认" : "正在准备操作")
                    .font(.system(size: 9.5))
                    .foregroundStyle(UD.text4)
            }
            .padding(.horizontal, 10)
            .frame(height: 43)
            .overlay(alignment: .top) { Rectangle().fill(UD.border).frame(height: 1) }
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
                .onHover { isHovering = $0 }
                // 悬停门控：行上本来就有 `isHovering`，不悬停的行不必给
                // `NSToolTipManager` 留一块每个滚动 tick 都要重算的区域。
                .help(whenHovering: isHovering && canEdit, "点击编辑并重发")
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
