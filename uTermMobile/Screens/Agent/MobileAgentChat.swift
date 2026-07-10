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

    @Environment(\.modelContext) private var context
    @Environment(\.mAccent) private var accent
    @Query(sort: [SortDescriptor(\AIProvider.sortOrder)]) private var providers: [AIProvider]
    @Query(sort: [SortDescriptor(\ChatSession.updatedAt, order: .reverse)]) private var sessions: [ChatSession]

    @State private var addingProvider = false
    /// 活动 provider 的持久化选择（与 macOS `@AppStorage("activeProviderID")` 对齐：跨会话 / 重启记忆）。
    @AppStorage("mobileAgentActiveProviderID") private var activeProviderIDString = ""
    /// 「自然语言 → 执行」信任档位，持久化（与 macOS `@AppStorage("agentSafety")` 对齐）。
    @AppStorage("mobileAgentSafety") private var safetyRaw = AgentSafety.readAuto.rawValue

    private var ctx: String { serverContext ?? "" }
    private var safety: AgentSafety { AgentSafety(rawValue: safetyRaw) ?? .readAuto }
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
        .background(M.canvas)
        .sheet(isPresented: $addingProvider) { ProviderFormSheet() }
        .onAppear { configureModel() }
        .onChange(of: providers) { _, list in model.providers = list }
        // 「自动执行」档位：进入「待确认」即自动批准首个 pending（逐条迭代）；切档 / 切回前台时补批一次。
        .onChange(of: model.state) { _, _ in autoApproveNextIfNeeded() }
        .onChange(of: safetyRaw) { _, _ in autoApproveNextIfNeeded() }
        .onChange(of: isActive) { _, _ in autoApproveNextIfNeeded() }
    }

    /// 进入视图时把持久化上下文 / provider 列表 / 活动 provider / SSH 执行器灌进状态机。
    ///
    /// `attach(context:)` 开启落库：每轮对话写穿到 SwiftData `ChatSession` / `ChatMessageRecord`
    /// （经 CloudKit 与 macOS 共享同一历史库）。`attach` 幂等（仅首次生效），会话由首次发送
    /// 惰性创建——空 Agent 标签不会污染历史。
    private func configureModel() {
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
        if model.executor == nil {
            let made = try? WorkspaceCommandExecutorFactory.make(server: host, container: context.container)
            model.executor = made?.executor
        }
        autoApproveNextIfNeeded()
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
                MIcon(name: "ellipsis", size: 16, color: M.text2).frame(width: 32, height: 32)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 7)
        // v2 禁半透明材质浮层：实体 overlay 面 + 发丝分隔（贴边 bar 不带投影）
        .background(M.overlay)
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
                    ForEach(model.messages) { msg in
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
            }
            .scrollIndicators(.hidden)
            .defaultScrollAnchor(.bottom)
            .onChange(of: model.messages.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: model.messages.last?.text) { _, _ in scrollToBottom(proxy) }
            .onChange(of: model.state) { _, _ in scrollToBottom(proxy) }
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
                        approvalEnabled: model.state == .awaitingApproval && !safety.autoApprovesPending,
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

    private func firstPendingToolCallID() -> String? {
        for m in model.messages {
            if let c = m.toolCalls.first(where: { $0.status == .pending }) { return c.id }
        }
        return nil
    }

    /// 「自动执行」档下批准首个待确认的 pending 工具调用（无则 no-op）。仅在该会话**激活且处于
    /// Agent 模式**（`isActive`）时放行——后台标签停在审批卡，待用户切回前台再继续。
    /// `approveAndRun` 自带 `.awaitingApproval` 门禁且 @MainActor 串行，重复调用安全。
    private func autoApproveNextIfNeeded() {
        guard isActive, safety.autoApprovesPending, model.state == .awaitingApproval,
              let id = firstPendingToolCallID() else { return }
        tasks.add(Task { await model.approveAndRun(id: id) })
    }

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
        // v2 禁半透明材质浮层：实体 overlay 面 + 发丝分隔（贴边 bar 不带投影）
        .background(M.overlay)
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
/// （`closeTab` / 连接中页取消）时 `cancelAll()`——取消会令 `AssistantModel` 里消费 LLM 字节流的
/// `for try await` 随之结束（`AsyncThrowingStream` 对消费方取消会 finish），不再空耗 token / 网络。
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
