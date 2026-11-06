import AgentKit
import SwiftUI
import SwiftData

/// 可嵌入的 Agent 聊天面板：用于终端连接页的「Agent 模式」（对齐 macOS 终端窗口的
/// 终端 ⇄ Agent 切换，即 `TerminalAgentView`）。
///
/// 编排与 macOS 是同一份代码，这里只有 iOS 的画法：
/// - 状态机：`AssistantModel`（流式 Markdown + `run_command` 工具调用 + 审批 / 工具循环 +
///   待发队列 + 停止 + 会话落库），由外部（`TermTab`）持有，「终端 / Agent」来回切换时保活。
/// - 接线：`AssistantBindingModifier`（providers / 活动 provider）+ `agentSession`
///   （落库 + 审批档位），与 macOS 工作区 / 终端窗口同一组 modifier。
/// - 输入区的行为：`AgentComposerSupport`（模型菜单、思考深度、排队、停止、上下文附加）。
/// - 命令执行：共享后端 `WorkspaceCommandExecutorFactory`——每条命令独立开一条一次性
///   SSH exec 连接，结果折回卡片、Agent 据此续轮。
/// - 贴底跟随：`AgentScrollPolicy`（听布局、不听消息模型，理由见其注释）。
struct MobileAgentChat: View {
    /// 由所属终端会话持有，跨模式切换保活对话历史。
    @Bindable var model: AssistantModel
    /// 当前会话连接的目标主机：用于构造 `run_command` 的 SSH 执行器。
    let host: ServerProfile
    /// Agent 的在途驱动 Task 集（由 `TermTab` 持有）：会话关闭时统一取消，见 `TermTab.agentTasks`。
    let tasks: MAgentTaskBag
    /// 该会话是否为「当前激活且处于 Agent 模式」。
    var isActive: Bool = true
    /// 当前主机描述（如「web-01（root@10.0.0.1:22）」）。
    var serverContext: String? = nil
    /// 一次最多挂载多少条消息（`AgentMessageWindow`）。与 macOS `AssistantView` /
    /// `TerminalAgentView` 同一形态、同一处方：**只裁渲染不裁数据**，
    /// `model.messages` / SwiftData 记录 / 进模型的上下文一条不动。
    /// `0` 表示不裁（探针的对照臂）。
    var messageWindowLimit: Int = AgentMessageWindow.defaultLimit

    @Environment(\.modelContext) private var context
    @Environment(\.mAccent) private var accent
    /// 工具执行器的工厂注入口（默认 `.live` —— 真 SSH 执行器）。
    @Environment(\.agentCommandExecutorFactory) private var executorFactory
    @Query(sort: [SortDescriptor(\AIProvider.sortOrder)]) private var providers: [AIProvider]
    // 会话历史下拉只列最近 `ChatSessionQueries.recentLimit` 条（与 macOS 的
    // `AssistantView` / `TerminalAgentView` 同一个描述符）。`TerminalScreen` 给**每个终端 tab**
    // 都挂了一份 `MobileAgentChat`，无 `fetchLimit` 的话开 n 个标签就是 n 份全表。
    @Query(ChatSessionQueries.recent) private var sessions: [ChatSession]

    @State private var addingProvider = false
    @State private var managingProviders = false
    /// 用户点开「显示更早」后放大的上限；`nil` 表示仍用 `messageWindowLimit`。
    @State private var expandedWindowLimit: Int?
    @State private var followsTail = true
    @State private var tailScroll = TailScrollCoalescer()
    @State private var sendCount = 0
    /// 活动 provider 的持久化选择（与 macOS 共用 key，可经 iCloud KVS 同步）。
    @AppStorage(PreferenceKey.activeProviderID) private var activeProviderIDString = ""
    /// 「自然语言 → 执行」信任档位（与 macOS 共用 key，可经 iCloud KVS 同步）。
    @AppStorage(PreferenceKey.agentSafety) private var safetyRaw = AgentSafety.readAuto.rawValue

    private var ctx: String { serverContext ?? "" }
    private var safety: AgentSafety { AgentSafety(rawValue: safetyRaw) ?? .readAuto }
    private var safetyBinding: Binding<AgentSafety> {
        Binding(get: { safety }, set: { safetyRaw = $0.rawValue })
    }

    var body: some View {
        Group {
            if providers.isEmpty {
                MEmptyState(icon: "spark", title: "配置模型服务",
                            message: "添加 Anthropic 或 OpenAI 兼容服务，即可让 Agent 协助你操作这台主机。",
                            actionTitle: "添加模型服务", action: { addingProvider = true })
                    .frame(maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    contextBar
                    messageList
                        // 输入区挂成底部 bar：随键盘上浮，消息从它下面滚过（iOS 26 有边缘虚化）。
                        .mAgentBottomBar { bottomBar }
                }
                .background(commandReturnShortcut)
            }
        }
        // 与终端同一个工作面（Agent 与终端在同一条会话标签栏下切换，底色不跳）。
        .background(M.surface, ignoresSafeAreaEdges: .mSessionBody)
        .modifier(AssistantBindingModifier(assistant: model, providers: providers,
                                           activeProviderIDString: activeProviderIDString))
        .agentSession(model, safety: safety)
        .onAppear(perform: configureExecutor)
        .sensoryFeedback(.impact(weight: .light), trigger: sendCount)
        .sheet(isPresented: $addingProvider) {
            NewProviderSheet { activeProviderIDString = $0.id.uuidString }.mSheetContentMargins(.form)
        }
        .sheet(isPresented: $managingProviders) { ProvidersScreen(showsDone: true).mSheetContentMargins(.form) }
    }

    /// 执行器一次性构造（host 固定不变）：缺失则状态机不暴露工具，退化为纯文本对话。
    private func configureExecutor() {
        if model.executor == nil {
            model.executor = executorFactory.make(host, context.container)
        }
    }

    // MARK: - 上下文条

    /// 主机 · 会话历史 · 新对话（对齐 macOS `TerminalAgentView` 的上下文条）。
    /// 模型 / 思考深度 / 审批档位都在输入区，不在这里。
    private var contextBar: some View {
        HStack(spacing: 4) {
            Image(systemName: "sparkles").font(.system(size: 12)).foregroundStyle(accent)
            Text(model.currentSession?.title.isEmpty == false ? model.sessionTitle : host.name)
                .font(M.sans(13, weight: .medium)).foregroundStyle(M.text2)
                .lineLimit(1)
                .padding(.leading, 4)
            Spacer(minLength: 6)

            MMenu {
                if sessions.isEmpty {
                    Text("还没有历史会话")
                } else {
                    ForEach(sessions) { session in
                        Button { model.load(session) } label: {
                            if model.currentSession?.id == session.id {
                                Label(session.displayTitle, systemImage: "checkmark")
                            } else {
                                Text(session.displayTitle)
                            }
                        }
                    }
                }
            } label: {
                barIcon("clock.arrow.circlepath")
            }
            .accessibilityLabel("会话历史")

            Button { model.startNewSession() } label: { barIcon("square.and.pencil") }
                .disabled(model.messages.isEmpty)
                .accessibilityLabel("新对话")
        }
        .padding(.leading, 16).padding(.trailing, 4)
        .frame(height: 44)
        .overlay(alignment: .bottom) { Rectangle().fill(M.divider).frame(height: 1) }
    }

    /// 两枚图标装进同一个 17pt 方框、按图形边界居中。按字号排的话 SF Symbol 走文字基线，
    /// `square.and.pencil` 的笔尖伸出右上角、字形框跟 `clock.arrow.circlepath` 不一样，
    /// 两枚就一高一低。
    private func barIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .resizable()
            .scaledToFit()
            .fontWeight(.regular)
            .frame(width: 17, height: 17)
            .foregroundStyle(M.text2)
            .frame(width: M.minTarget, height: M.minTarget)
            .contentShape(Rectangle())
    }

    // MARK: - 消息列表

    @ViewBuilder
    private var messageList: some View {
        if model.messages.isEmpty {
            ScrollView { emptyState.mReadableColumn() }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        earlierMessagesButton
                        ForEach(mountedMessages) { msg in
                            messageRow(msg).id(msg.id)
                        }
                        if let err = model.bannerError {
                            Label(err, systemImage: "exclamationmark.triangle.fill")
                                .font(M.sans(13)).foregroundStyle(M.danger)
                                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(M.danger.opacity(0.08),
                                            in: RoundedRectangle(cornerRadius: MRadius.lg, style: .continuous))
                        }
                        // 底部留白由锚点承担：锚点下面再垫 padding，贴底就永远差这一截。
                        Color.clear.frame(height: 8).id(Self.bottomAnchor)
                    }
                    .padding(.horizontal, 16).padding(.top, 14)
                    // 宽屏（iPad / iPhone Duo 展开）消息收在易读列宽里。
                    .mReadableColumn()
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
                .defaultScrollAnchor(.bottom)
                .onScrollPhaseChange { _, phase, context in
                    if phase == .tracking || phase == .interacting {
                        followsTail = false
                        tailScroll.cancel()
                    }
                    if phase == .idle {
                        followsTail = AgentScrollPolicy.isNearBottom(
                            visibleMaxY: context.geometry.visibleRect.maxY,
                            contentHeight: context.geometry.contentSize.height)
                    }
                }
                // 贴底跟随听布局、不听消息模型（理由见 `AgentScrollPolicy.needsRepin`）。
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
                // 自己发了一条：无论刚才翻到哪儿，都回到底部跟随。
                .onChange(of: sendCount) { _, _ in
                    followsTail = true
                    scheduleScrollToBottom(proxy)
                }
                // 换会话（首条消息换身份）时把「显示更早」放开的窗口收回默认值。
                .onChange(of: model.messages.first?.id) { _, _ in expandedWindowLimit = nil }
                .onDisappear {
                    tailScroll.cancel()
                }
            }
        }
    }

    private static let bottomAnchor = "magent.bottom"

    private func scheduleScrollToBottom(_ proxy: ScrollViewProxy) {
        guard followsTail else { return }
        // 合并到最多每 100ms 一次，与 Markdown 重排节奏一致，避免逐 token 重入布局。
        tailScroll.schedule { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
    }

    // MARK: - 空状态（按诊断 / 配置 / 部署分组的示例）

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 20)).foregroundStyle(accent)
                    .frame(width: 40, height: 40)
                    .background(accent.opacity(0.14), in: RoundedRectangle(cornerRadius: MRadius.md, style: .continuous))
                Text("用自然语言操作 \(host.name)")
                    .font(M.sans(18, weight: .semibold)).foregroundStyle(M.text)
                Text("描述你想做的事，Agent 会翻译成命令，按审批档位征求确认后在远端执行。")
                    .font(M.sans(14)).foregroundStyle(M.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(AgentPromptExamples.groups, id: \.tag) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text(group.tag)
                        .font(M.sans(12, weight: .semibold)).tracking(0.4)
                        .foregroundStyle(M.text3)
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(group.items, id: \.self) { item in
                                Button { model.input = item } label: {
                                    Text(item)
                                        .font(M.sans(14)).foregroundStyle(M.text2)
                                        .padding(.horizontal, 13).frame(height: 36)
                                        .background(M.fillFaint, in: Capsule())
                                }
                                .buttonStyle(MPressStyle())
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .scrollClipDisabled()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20).padding(.top, 28).padding(.bottom, 16)
    }

    // MARK: - 渲染窗口

    private var effectiveWindowLimit: Int {
        max(expandedWindowLimit ?? messageWindowLimit, 0)
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
            Button {
                expandedWindowLimit = AgentMessageWindow.expanded(
                    effectiveWindowLimit, count: model.messages.count)
            } label: {
                Label("显示更早的 \(min(hidden, AgentMessageWindow.step)) 条", systemImage: "chevron.up")
                    .font(M.sans(12)).foregroundStyle(M.text3)
                    .padding(.horizontal, 12).frame(height: 32)
                    .background(Capsule().fill(M.fillFaint))
                    .contentShape(Capsule())
            }
            .buttonStyle(MPressStyle())
            .accessibilityLabel("显示更早的消息，还有 \(hidden) 条")
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - 消息行

    @ViewBuilder
    private func messageRow(_ m: ChatMessage) -> some View {
        if m.role == .user {
            HStack {
                Spacer(minLength: 48)
                Text(m.text)
                    .font(M.sans(15)).foregroundStyle(.white)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(accent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .mContextMenu {
                        Button { UIPasteboard.general.string = m.text } label: {
                            Label("复制", systemImage: "doc.on.doc")
                        }
                        Button { model.input = m.text } label: {
                            Label("放回输入框", systemImage: "arrow.uturn.down")
                        }
                    }
            }
        } else {
            // 助手回复裸排（无气泡外框）——对齐 macOS `TerminalAgentView`：只有用户消息有气泡，
            // 助手是裸文本 + 整宽命令卡。
            VStack(alignment: .leading, spacing: 8) {
                if !m.text.isEmpty {
                    MStreamingMarkdown(text: m.text, isStreaming: model.isStreamingTail(m))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if model.isStreamingTail(m) {
                    MAgentThinkingIndicator()
                } else if m.toolCalls.isEmpty {
                    Text("…").font(M.sans(15)).foregroundStyle(M.text3)
                }
                ForEach(m.toolCalls) { call in
                    VStack(alignment: .leading, spacing: 4) {
                        MToolCall(
                            label: call.explanation ?? "运行命令",
                            command: call.command,
                            status: mStatus(call),
                            approvalEnabled: model.state == .awaitingApproval,
                            onRun: { tasks.add(Task { await model.approveAndRun(id: call.id) }) },
                            onSkip: { tasks.add(Task { await model.skip(id: call.id) }) })
                        if let summary = model.approvalSummary(for: call) {
                            Text(summary)
                                .font(M.sans(12)).foregroundStyle(M.text3)
                                .padding(.horizontal, 4)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func mStatus(_ call: ToolCallState) -> MToolCall.Status {
        switch call.phase {
        case .pending: return .pending
        case .running: return .running
        case .done: return .done(output: call.output)
        }
    }

    // MARK: - 输入区

    private var bottomBar: some View {
        VStack(spacing: 8) {
            MAgentQueueStrip(model: model)
            MAgentComposer(
                model: model,
                safety: safetyBinding,
                activeProviderIDString: $activeProviderIDString,
                placeholder: "描述你想做的事…",
                onSend: send,
                onAttach: { model.appendContext(ctx) },
                onManageProviders: { managingProviders = true })
        }
        .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 8)
        .mReadableColumn()
    }

    /// 同步清空输入再异步提交——避免回车后「先全选再发」的闪烁。忙碌时由状态机入队。
    private func send() {
        guard let text = model.takeDraft() else { return }
        sendCount += 1
        tasks.add(Task { await model.submit(text: text, serverContext: ctx) })
    }

    /// 硬件键盘 ⌘↵：有待确认命令则运行最早那条，否则发送（与 macOS 同一语义）。
    private func handleCommandReturn() {
        if let id = model.commandReturnTarget {
            tasks.add(Task { await model.approveAndRun(id: id) })
        } else {
            send()
        }
    }

    private var commandReturnShortcut: some View {
        Button("", action: handleCommandReturn)
            .keyboardShortcut(.return, modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }
}

// MARK: - 待发队列

/// 待发队列条带：Agent 忙碌时排进 `queuedMessages`、尚未发出的消息（对齐 macOS
/// `AgentQueueStrip`）。点一行载入输入框编辑，行尾可移除。
private struct MAgentQueueStrip: View {
    let model: AssistantModel

    var body: some View {
        if !model.queuedMessages.isEmpty {
            VStack(spacing: 6) {
                ForEach(model.queuedMessages) { row($0) }
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func row(_ item: QueuedMessage) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "clock").font(.system(size: 12)).foregroundStyle(M.text4)
            Text(item.text)
                .font(M.sans(14)).foregroundStyle(M.text2)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { model.removeQueued(id: item.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(M.text3)
                    .frame(width: 36, height: 36).contentShape(Rectangle())
            }
            .buttonStyle(MPressStyle())
            .accessibilityLabel("移除")
        }
        .padding(.leading, 12)
        .background(M.fillFaint, in: RoundedRectangle(cornerRadius: MRadius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: MRadius.md, style: .continuous)
            .strokeBorder(M.border, style: StrokeStyle(lineWidth: 1, dash: [3])))
        .contentShape(Rectangle())
        .onTapGesture { model.loadQueuedForEditing(id: item.id) }
        // 整行可点（= 载入编辑），但 `onTapGesture` 对读屏不可见：合成一个元素并补上动作。
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("排队消息：\(item.text)")
        .accessibilityHint("点按载入到输入框编辑")
        .accessibilityAction { model.loadQueuedForEditing(id: item.id) }
        .accessibilityAction(named: "移除") { model.removeQueued(id: item.id) }
    }
}

// MARK: - 思考中

/// 等首个 token 时的占位：「思考中」+ 已等秒数（对齐 macOS `AgentThinkingIndicator`）。
/// 图标脉动走系统符号动效（不是 SwiftUI `.repeatForever`，后者会让整窗满帧重绘）；
/// 秒数每秒才刷一次。
private struct MAgentThinkingIndicator: View {
    @State private var startedAt = Date()
    @Environment(\.mAccent) private var accent

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "sparkles")
                .font(.system(size: 13))
                .foregroundStyle(accent)
                .symbolEffect(.pulse, options: .repeating)
            Text("思考中").font(M.sans(14, weight: .medium)).foregroundStyle(M.text3)
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                let seconds = Int(context.date.timeIntervalSince(startedAt))
                Text(seconds > 0 ? "\(seconds)s" : "")
                    .font(M.mono(12)).foregroundStyle(M.text4)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Agent 正在思考")
    }
}

// MARK: - 底部 bar

private extension View {
    /// iOS 26：`safeAreaBar` —— 内容从 bar 下面滚过时系统做滚动边缘虚化；
    /// 更早的系统退回 `safeAreaInset`。两者都随键盘上浮。
    @ViewBuilder
    func mAgentBottomBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        if #available(iOS 26.0, *) {
            safeAreaBar(edge: .bottom, spacing: 0, content: bar)
                .scrollEdgeEffectStyle(.soft, for: .bottom)
        } else {
            safeAreaInset(edge: .bottom, spacing: 0, content: bar)
        }
    }
}

/// Agent 的在途驱动 Task 集合（提交 / 批准 / 跳过）。`TermTab` 持有一份，会话关闭
/// （`closeTab` / 连接中页取消）时先 `AssistantModel.dispose()`，再 `cancelAll()`，停止模型请求
/// 和自动续轮。已经发往服务器的命令保留结果收尾，取消驱动任务不表示远端进程已停止。
/// **只在显式关闭路径取消**（不挂 `onDisappear`——横屏切换 size class 重建外壳时视图会
/// disappear，但会话仍存活）。
@MainActor
final class MAgentTaskBag {
    private var tasks: [Task<Void, Never>] = []

    func add(_ task: Task<Void, Never>) {
        tasks.removeAll { $0.isCancelled }
        tasks.append(task)
    }

    func cancelAll() {
        for task in tasks { task.cancel() }
        tasks.removeAll()
    }
}
