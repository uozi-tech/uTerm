import AgentKit
import SwiftUI
import SwiftData

/// 可嵌入的 Agent 聊天面板：用于终端连接页的「Agent 模式」（对齐 macOS 终端窗口的
/// 终端 ⇄ Agent 切换）。
///
/// 直接复用 macOS 的 `AssistantModel` 状态机（流式 Markdown + `run_command` 工具调用 +
/// 审批 / 工具循环 + 会话落库），由外部（`TermTab`）持有，使会话内容在「终端 / Agent」
/// 来回切换时得以保留。命令执行复用共享后端 `WorkspaceCommandExecutorFactory`——每条命令
/// 独立开一条一次性 SSH exec 连接，结果折回卡片、Agent 据此续轮（与 macOS 终端窗口一致）。
/// 对话落库到 SwiftData `ChatSession`（经 CloudKit 与 macOS 共享同一历史），顶栏菜单可
/// 新开 / 切回历史会话。渲染复用移动端 `MStreamingMarkdown` / `MToolCall`。无 provider 时引导添加。
struct MobileAgentChat: View {
    /// 由所属终端会话持有，跨模式切换保活对话历史。
    @Bindable var model: AssistantModel
    /// 当前会话连接的目标主机：用于构造 `run_command` 的 SSH 执行器。
    let host: ServerProfile
    /// Agent 的在途驱动 Task 集（由 `TermTab` 持有）：会话关闭时统一取消，见 `TermTab.agentTasks`。
    let tasks: MAgentTaskBag
    /// 该会话是否为「当前激活且处于 Agent 模式」。仅激活时才在 `.auto` 档自动批准命令——
    /// 避免后台（不可见）标签在用户看着另一台主机时自动在本机执行写操作。
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
    /// 工具执行器的工厂注入口（默认 `.live` —— 真 SSH 执行器，生产路径与改前逐字等价）。
    @Environment(\.agentCommandExecutorFactory) private var executorFactory
    @Query(sort: [SortDescriptor(\AIProvider.sortOrder)]) private var providers: [AIProvider]
    // 会话历史下拉只列最近 `ChatSessionQueries.recentLimit` 条（与 macOS 的
    // `AssistantView` / `TerminalAgentView` 同一个描述符）。改前是无 `fetchLimit`
    // 的 `@Query`，一开会话就把库里所有 `ChatSession` 取出来物化；
    // 更糟的是 `TerminalScreen` 给**每个终端 tab** 都挂了一份 `MobileAgentChat`，
    // 开 n 个标签就是 n 份全表。下拉本身只 `prefix(20)`。
    @Query(ChatSessionQueries.recent) private var sessions: [ChatSession]

    @State private var addingProvider = false
    /// 用户点开「显示更早」后放大的上限；`nil` 表示仍用 `messageWindowLimit`。
    /// 换会话时收回默认值。
    @State private var expandedWindowLimit: Int?
    /// 活动 provider 的持久化选择（与 macOS 共用 key，可经 iCloud KVS 同步）。
    @AppStorage("activeProviderID") private var activeProviderIDString = ""
    /// 「自然语言 → 执行」信任档位（与 macOS 共用 key，可经 iCloud KVS 同步）。
    @AppStorage("agentSafety") private var safetyRaw = AgentSafety.readAuto.rawValue

    private var ctx: String { serverContext ?? "" }
    private var safetyBinding: Binding<AgentSafety> {
        Binding(get: { AgentSafety(rawValue: safetyRaw) ?? .readAuto },
                set: { safetyRaw = $0.rawValue })
    }

    var body: some View {
        VStack(spacing: 0) {
            if providers.isEmpty {
                MEmptyState(icon: "spark", title: "配置 AI Provider",
                            message: "添加 Anthropic 或 OpenAI 兼容服务，即可让 Agent 协助你操作这台主机。",
                            actionTitle: "添加 Provider", action: { addingProvider = true })
                .frame(maxHeight: .infinity)
            } else {
                providerBar
                // 输入条作为消息列表的底部安全区 inset：键盘弹出时随安全区上浮，始终悬于键盘之上。
                messageList
                    .safeAreaInset(edge: .bottom, spacing: 0) { composer }
            }
        }
        // 与终端同一个工作面（Agent 与终端在同一条会话标签栏下切换，底色不跳）。
        .background(M.surface, ignoresSafeAreaEdges: .mSessionBody)
        .sheet(isPresented: $addingProvider) { ProviderFormSheet() }
        .onAppear { configureModel() }
        .onChange(of: providers) { _, list in model.providers = list }
        .onChange(of: activeProviderIDString) { _, value in
            model.activeProviderID = UUID(uuidString: value)
        }
        // 信任档位灌进状态机（与桌面 AssistantView / TerminalAgentView 同一写法）。
        // 此前移动端从未赋值，approvalMode 恒为 .confirm，拨盘选什么都不生效。
        .onChange(of: safetyRaw) { _, _ in model.approvalMode = safetyBinding.wrappedValue }
    }

    /// 进入视图时把持久化上下文 / provider 列表 / 活动 provider / SSH 执行器灌进状态机。
    ///
    /// `attach(context:)` 开启落库：每轮对话写穿到 SwiftData `ChatSession` / `ChatMessageRecord`
    /// （经 CloudKit 与 macOS 共享同一历史库）。`attach` 幂等（仅首次生效），会话由首次发送
    /// 惰性创建——空 Agent 标签不会污染历史。
    private func configureModel() {
        model.approvalMode = safetyBinding.wrappedValue
        model.attach(context: context)
        model.providers = providers
        // 活动 provider：优先用持久化选择，失效（已删除 / 首次）则回退排序首个。
        if model.activeProviderID == nil {
            if let saved = UUID(uuidString: activeProviderIDString),
               providers.contains(where: { $0.id == saved }) {
                model.activeProviderID = saved
            } else {
                model.activeProviderID = providers.first?.id
            }
        }
        // 执行器一次性构造（host 固定不变）：缺失则状态机不暴露工具，退化为纯文本对话。
        // 经 `\.agentCommandExecutorFactory` 注入口取 —— 默认 `.live` 即改前那两行。
        if model.executor == nil {
            model.executor = executorFactory.make(host, context.container)
        }
    }

    private func selectProvider(_ p: AIProvider) {
        model.activeProviderID = p.id
        activeProviderIDString = p.id.uuidString
    }

    // MARK: - 顶部 provider 细条

    private var providerBar: some View {
        HStack(spacing: 8) {
            MIcon(name: "spark", size: 13, color: accent)
            if let provider = model.activeProvider {
                Text("\(provider.name) · \(provider.model.isEmpty ? provider.kind.displayName : provider.model)")
                    .font(M.mono(11.5)).foregroundStyle(M.text3).lineLimit(1)
            }
            Spacer(minLength: 6)
            Menu {
                Section("会话") {
                    Button { model.startNewSession() } label: { Label("新对话", systemImage: "plus.bubble") }
                    if !sessions.isEmpty {
                        Menu {
                            ForEach(sessions.prefix(20)) { s in
                                Button { model.load(s) } label: {
                                    Label(s.title.isEmpty ? "新对话" : s.title,
                                          systemImage: model.currentSession?.id == s.id ? "checkmark" : "")
                                }
                            }
                        } label: { Label("历史会话", systemImage: "clock.arrow.circlepath") }
                    }
                }
                Section("Provider") {
                    ForEach(providers) { p in
                        Button { selectProvider(p) } label: {
                            Label(p.name, systemImage: model.activeProvider?.id == p.id ? "checkmark" : "")
                        }
                    }
                    Button { addingProvider = true } label: { Label("添加 Provider", systemImage: "plus") }
                }
            } label: {
                MIcon(name: "ellipsis", size: 16, color: M.text2)
                    .frame(width: M.minTarget, height: 36)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("会话与 Provider"))
        }
        .padding(.leading, 16).padding(.trailing, 6).padding(.vertical, 2)
        // 同一工作面上只用底边 hairline 分区，不再叠 overlay 底色。
        .overlay(alignment: .bottom) { Rectangle().fill(M.divider).frame(height: 1) }
    }

    // MARK: - 消息列表

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if model.messages.isEmpty {
                        Text("问我任何关于这台主机的运维问题，我会在确认后帮你执行命令。")
                            .font(M.sans(14)).foregroundStyle(M.text4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 40)
                    }
                    earlierMessagesButton
                    ForEach(mountedMessages) { msg in
                        messageRow(msg).id(msg.id)
                    }
                    if let err = errorText {
                        Text(err).font(M.sans(12)).foregroundStyle(M.danger)
                            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(M.danger.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                // 宽屏（iPad / iPhone Duo 展开）消息收在易读列宽里，避免一行拉到七八十个汉字。
                .mReadableColumn()
            }
            .scrollIndicators(.hidden)
            .defaultScrollAnchor(.bottom)
            // 贴底跟随的三路监听压成一个 Equatable 指纹（镜像 macOS `ChatTailSignature`）：
            // 每条 `onChange` 都要在每次 body 求值时算一遍旧值 / 新值，
            // 其中 `model.messages.last?.text` 会把一整份长正文存进 onChange 的旧值。
            // 指纹用 `utf8.count`（原生 Swift 字符串 O(1)），流式期间正文只增不减，
            // 长度就是忠实的变化指纹。
            .onChange(of: MChatTailSignature(model)) { _, _ in scrollToBottom(proxy) }
            // 换会话（首条消息换身份）时把「显示更早」放开的窗口收回默认值。
            .onChange(of: model.messages.first?.id) { _, _ in expandedWindowLimit = nil }
        }
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
            HStack {
                Spacer(minLength: 0)
                Button {
                    expandedWindowLimit = AgentMessageWindow.expanded(
                        effectiveWindowLimit, count: model.messages.count)
                } label: {
                    HStack(spacing: 6) {
                        MIcon(name: "chev-down", size: 8, color: M.text3)
                            .rotationEffect(.degrees(180))
                        Text("显示更早的 \(min(hidden, AgentMessageWindow.step)) 条")
                            .font(M.sans(12))
                    }
                    .foregroundStyle(M.text3)
                    .padding(.horizontal, 12).frame(height: 32)
                    .background(Capsule().fill(M.fillFaint))
                    .contentShape(Capsule())
                }
                .buttonStyle(MPressStyle())
                .accessibilityLabel("显示更早的消息，还有 \(hidden) 条")
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private static let bottomAnchor = "magent.bottom"
    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
    }

    @ViewBuilder
    private func messageRow(_ m: ChatMessage) -> some View {
        if m.role == .user {
            HStack {
                Spacer(minLength: 40)
                Text(m.text)
                    .font(M.sans(15)).foregroundStyle(.white)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(accent)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if !m.text.isEmpty {
                    MStreamingMarkdown(text: m.text, isStreaming: isStreamingTail(m))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if !isStreamingTail(m) && m.toolCalls.isEmpty {
                    Text("…").font(M.sans(15)).foregroundStyle(M.text3)
                }
                ForEach(m.toolCalls) { call in
                    MToolCall(
                        label: call.explanation ?? "运行命令",
                        command: call.command,
                        status: mStatus(call),
                        approvalEnabled: model.state == .awaitingApproval,
                        onRun: { tasks.add(Task { await model.approveAndRun(id: call.id) }) },
                        onSkip: { tasks.add(Task { await model.skip(id: call.id) }) })
                }
            }
            // 助手回复裸排（无气泡外框）——对齐 macOS `TerminalAgentView`：只有用户消息有气泡，
            // 助手是裸文本 + 整宽命令卡。
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func isStreamingTail(_ m: ChatMessage) -> Bool {
        m.id == model.messages.last?.id && model.state == .streaming
    }

    private func mStatus(_ call: ToolCallState) -> MToolCall.Status {
        switch call.status {
        case .pending: return .pending
        case .running: return .running
        case .done, .failed, .skipped: return .done(output: call.output)
        }
    }

    /// 错误红条：仅当错误尚未内联进末条助手气泡时显示——避免与 `AssistantModel` 追加进
    /// 消息文本的「[错误：…]」重复。provider / key / baseURL 校验失败发生在追加助手消息之前
    /// （无内联文本），此时红条是唯一的错误反馈，故保留。
    private var errorText: String? {
        guard case .failed(let msg) = model.state else { return nil }
        if let last = model.messages.last, last.role == .assistant, last.text.contains("[错误：") {
            return nil
        }
        return msg
    }

    // MARK: - 自动批准（.auto 档）

    // MARK: - 输入区

    private var composer: some View {
        VStack(spacing: 8) {
            HStack {
                MSafetyDial(safety: safetyBinding)
                Spacer(minLength: 6)
                if model.isBusy {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        Text(model.state == .running ? "执行中" : "生成中")
                            .font(M.sans(11)).foregroundStyle(M.text4)
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("发消息…", text: $model.input, axis: .vertical)
                    .font(M.sans(15)).foregroundStyle(M.text)
                    .lineLimit(1...5)
                    .textInputAutocapitalization(.sentences)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    // v2 composer 浮层化：实体 overlay 面 + 细边、无投影（user 定）
                    .background(M.overlay)
                    .overlay(RoundedRectangle(cornerRadius: 20).stroke(M.border, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 20))

                Button(action: send) {
                    MIcon(name: "send", size: 18, color: .white)
                        .frame(width: 44, height: 44)
                        .background(canSend ? accent : M.text4)
                        .clipShape(Circle())
                }
                .disabled(!canSend)
            }
        }
        .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 10)
        .mReadableColumn()
        // 不透明底（消息从它下面滚过）；与工作面同色，只靠顶边 hairline 分区。
        .background(M.surface, ignoresSafeAreaEdges: .mSessionBody)
        .overlay(alignment: .top) { Rectangle().fill(M.divider).frame(height: 1) }
    }

    private var canSend: Bool {
        !model.input.trimmingCharacters(in: .whitespaces).isEmpty && model.activeProvider != nil
    }

    /// 同步清空输入再异步提交——避免回车后「先全选再发」的闪烁。忙碌时由状态机入队。
    private func send() {
        let text = model.input
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        model.input = ""
        tasks.add(Task { await model.submit(text: text, serverContext: ctx) })
    }
}

/// Agent 的在途驱动 Task 集合（提交 / 批准 / 跳过 / 自动批准）。`TermTab` 持有一份，会话关闭
/// （`closeTab` / 连接中页取消）时先 `AssistantModel.dispose()`，再 `cancelAll()`，停止模型请求
/// 和自动续轮。已经发往服务器的命令保留结果收尾，取消驱动任务不表示远端进程已停止。
/// 等价于旧 `MobileAgentController.stop()`，补回随状态机迁移而丢失的取消能力。**只在显式关闭路径
/// 取消**（不挂 `onDisappear`——横屏切换 size class 重建外壳时视图会 disappear，但会话仍存活）。
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

/// 「贴底跟随」要监听的三路变化压成一个 `Equatable` 值（镜像 macOS `ChatTailSignature`）：
/// 尾消息身份、正文长度、尾消息的工具卡、状态机态。正文用 `utf8.count`
/// （原生 Swift 字符串是 O(1)）而不是整串 —— 流式期间正文只增不减，长度就是忠实指纹。
private struct MChatTailSignature: Equatable {
    let count: Int
    let lastID: UUID?
    let lastTextLength: Int
    let toolCalls: [ToolCallState]
    let state: AssistantModel.State

    @MainActor
    init(_ model: AssistantModel) {
        let last = model.messages.last
        count = model.messages.count
        lastID = last?.id
        lastTextLength = last?.text.utf8.count ?? 0
        toolCalls = last?.toolCalls ?? []
        state = model.state
    }
}
