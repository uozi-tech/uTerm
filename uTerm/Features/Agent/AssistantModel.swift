import SwiftUI
import SwiftData

/// AI 助手聊天的对话状态机。多 provider：调用方把 providers 列表与
/// activeProviderID 灌进来（通常源自 SwiftData @Query 与 @AppStorage）。
///
/// 会话历史：注入 `modelContext` 后，每轮对话写穿到 `ChatSession`/
/// `ChatMessageRecord`；未注入（如单测）时退化为纯内存，行为与旧版一致。
@MainActor
@Observable
final class AssistantModel {
    enum State: Equatable {
        case idle, streaming
        /// 流式结束后存在待确认（pending）的工具调用，等待用户批准/跳过。
        case awaitingApproval
        /// 已批准的工具调用正在执行。
        case running
        case failed(String)
    }

    private(set) var messages: [ChatMessage] = []
    /// 待发队列：Agent 忙碌时提交的消息，空闲后逐条派发。纯内存。
    private(set) var queuedMessages: [QueuedMessage] = []
    /// 当前处于内联编辑态的用户消息 id（视图驱动；会话切换时清空）。
    var editingMessageID: UUID?
    var input: String = ""
    private(set) var state: State = .idle

    /// 「猜你想问」追问气泡：每条助手回复落定后按上下文生成（优先 LLM，回退启发式）。
    /// 运行期纯内存，新消息 / 新会话即清空。
    private(set) var followUps: [String] = []
    private(set) var followUpsLoading = false
    @ObservationIgnored private var followUpTask: Task<Void, Never>?

    /// 命令执行器；nil 时不向模型暴露工具，行为退化为纯文本对话（旧版）。
    /// 由工作区在 SSH 连接建立后注入；断连时置 nil。
    var executor: CommandExecutor?

    /// 测试可缩短；生产默认 60 秒无文本 / 工具事件即结束静默 SSE。
    @ObservationIgnored var streamIdleTimeout: Duration = .seconds(60)

    /// 最近一次 `send` 携带的 serverContext，供工具续轮复用 system prompt。
    @ObservationIgnored private var lastServerContext = ""

    /// 持久化上下文；nil 时纯内存（单测路径）。由视图 `attach(context:)` 注入。
    var modelContext: ModelContext?
    /// 当前会话；首次发送时惰性创建，避免空会话污染历史。
    private(set) var currentSession: ChatSession?
    /// workspace 快照可能先于 SwiftData context 恢复；context 注入后再解析。
    @ObservationIgnored private var pendingRestoredSessionID: UUID?

    /// 顶栏展示的会话标题。
    var sessionTitle: String {
        if let t = currentSession?.title, !t.isEmpty { return t }
        return "新对话"
    }

    /// 全部已配置的 provider（外部灌入，按 sortOrder）。
    var providers: [AIProvider] = []
    /// 当前活动 provider id；nil 或失效时 fallback 到 sortOrder 最小者。
    var activeProviderID: UUID?

    /// 当前活动 provider；providers 空则 nil。
    var activeProvider: AIProvider? {
        if let id = activeProviderID,
           let p = providers.first(where: { $0.id == id }) {
            return p
        }
        return providers.min(by: { $0.sortOrder < $1.sortOrder })
    }
    var hasUsableProvider: Bool { activeProvider != nil }

    /// 注入持久化上下文（幂等：仅首次生效）。
    func attach(context: ModelContext) {
        if modelContext == nil {
            modelContext = context
        }
        resolvePendingRestoredSessionIfNeeded()
    }

    /// 开新对话：清空当前会话与消息，下次发送时再惰性建会话。
    func startNewSession() {
        currentSession = nil
        messages = []
        queuedMessages = []
        editingMessageID = nil
        clearFollowUps()
        if case .failed = state { state = .idle }
    }

    /// 切换到历史会话，载入其消息。
    func load(_ session: ChatSession) {
        guard session.id != currentSession?.id else { return }
        currentSession = session
        messages = session.orderedMessages.map(\.asChatMessage)
        queuedMessages = []
        editingMessageID = nil
        clearFollowUps()
        if case .failed = state { state = .idle }
    }

    func snapshot() -> AgentSnapshot {
        AgentSnapshot(currentSessionID: currentSession?.id, input: input)
    }

    func restore(from snapshot: AgentSnapshot?) {
        guard let snapshot else {
            pendingRestoredSessionID = nil
            currentSession = nil
            messages = []
            queuedMessages = []
            editingMessageID = nil
            input = ""
            if case .failed = state { state = .idle }
            return
        }

        input = snapshot.input
        pendingRestoredSessionID = snapshot.currentSessionID
        currentSession = nil
        messages = []
        queuedMessages = []
        editingMessageID = nil
        if case .failed = state { state = .idle }
        resolvePendingRestoredSessionIfNeeded()
    }

    /// 从首句话派生会话标题（单行、限长）。
    nonisolated static func deriveTitle(from prompt: String) -> String {
        let line = prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? prompt
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count <= 24 ? trimmed : String(trimmed.prefix(24)) + "…"
    }

    private let keychain: AgentKeychain
    /// 测试注入。非 nil 时绕过工厂直接用此 client。
    private let clientOverride: LLMClient?
    /// 测试注入。非 nil 时绕过 keychain。
    private let keyOverride: String?

    /// 生产构造。
    init(keychain: AgentKeychain = AgentKeychain()) {
        self.keychain = keychain
        self.clientOverride = nil
        self.keyOverride = nil
    }

    /// 测试构造：注入 client、provider、key。providers 仅含传入的一条；
    /// activeProviderID 自动指向它。
    init(client: LLMClient, provider: AIProvider, apiKey: String) {
        self.keychain = AgentKeychain()
        self.clientOverride = client
        self.keyOverride = apiKey
        self.providers = [provider]
        self.activeProviderID = provider.id
    }

    /// 是否忙碌：流式 / 工具执行 / 待批准。忙碌时提交即入队。
    var isBusy: Bool {
        switch state {
        case .streaming, .running, .awaitingApproval: return true
        case .idle, .failed: return false
        }
    }

    /// 视图统一提交入口：读+清空输入；忙碌则入队，空闲则发送。
    func submit(serverContext: String) async {
        let text = input
        input = ""
        await submit(text: text, serverContext: serverContext)
    }

    /// 显式文本提交入口：视图在 `onSubmit` 里**同步**清空输入后调它 —— 避免「回车后先
    /// 全选再发送」的闪烁（异步清空会留一帧选中态）。
    func submit(text: String, serverContext: String) async {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        if isBusy {
            enqueue(prompt)
        } else {
            await dispatch(prompt: prompt, serverContext: serverContext)
        }
    }

    /// 兼容旧调用方/测试：等价于 submit。
    func send(serverContext: String) async {
        await submit(serverContext: serverContext)
    }

    /// 发送一条用户 prompt：校验凭据 → 追加消息 → 落库 → 流式。
    private func dispatch(prompt: String, serverContext: String) async {
        guard let ctx = resolvedTurnContext() else { return }
        lastServerContext = serverContext
        let userMessage = ChatMessage(role: .user, text: prompt)
        messages.append(userMessage)
        clearFollowUps()   // 新用户输入 → 旧追问作废
        let session = ensureSession(firstPrompt: prompt)
        persist(userMessage, in: session)
        await streamAssistantTurn(provider: ctx.provider, key: ctx.key, baseURL: ctx.baseURL,
                                  serverContext: serverContext, session: session)
    }

    /// provider/key/baseURL 校验；任一缺失置 .failed 并返回 nil。
    private func resolvedTurnContext() -> (provider: AIProvider, key: String, baseURL: URL)? {
        guard let provider = activeProvider else {
            state = .failed("尚未配置 AI provider"); return nil
        }
        guard let key = keyOverride ?? keychain.load(for: provider.id) else {
            state = .failed("当前 provider 缺少 API Key"); return nil
        }
        guard let baseURL = resolveBaseURL(for: provider) else {
            state = .failed("当前 provider 的 baseURL 非法或不安全"); return nil
        }
        return (provider, key, baseURL)
    }

    /// 一轮助手流式：追加空 assistant 消息 → 落库 → 流式消费 `LLMEvent`
    /// （文本累加、工具调用追加为 pending 卡片）→ 依据是否有 pending 决定终态。
    /// `send` 与工具续轮（`continueAfterTools`）共用此实现。
    private func streamAssistantTurn(provider: AIProvider, key: String, baseURL: URL,
                                     serverContext: String, session: ChatSession?) async {
        let conversation = messages
        let assistantMessage = ChatMessage(role: .assistant, text: "")
        messages.append(assistantMessage)
        let assistantIndex = messages.count - 1
        let assistantRecord = persist(assistantMessage, in: session)
        state = .streaming

        var config = LLMRequestConfig(model: provider.model,
                                      baseURL: baseURL, apiKey: key)
        config.tools = executor != nil ? [.runCommand] : []
        config.streamIdleTimeout = streamIdleTimeout
        let client = clientOverride ?? LLMClientFactory.make(for: provider)
        let system = Self.systemPrompt(serverContext: serverContext)
        let textBuffer = StreamingTextBuffer { [weak self] text in
            guard let self, self.messages.indices.contains(assistantIndex) else { return }
            self.messages[assistantIndex].text += text
        }
        do {
            let events = withIdleTimeout(client.stream(
                messages: conversation, system: system, config: config),
                timeout: config.streamIdleTimeout)
            for try await event in events {
                switch event {
                case .text(let delta):
                    textBuffer.append(delta)
                case .toolCall(let call):
                    textBuffer.flush()
                    messages[assistantIndex].toolCalls.append(ToolCallState(from: call))
                }
            }
            textBuffer.flush()
            let toolCalls = messages[assistantIndex].toolCalls
            let visibleText = messages[assistantIndex].text
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if visibleText.isEmpty && toolCalls.isEmpty {
                let message = "模型未返回任何内容"
                messages[assistantIndex].text = "[错误：\(message)]"
                state = .failed(message)
            } else {
                let pending = toolCalls.contains { $0.status == .pending }
                state = pending ? .awaitingApproval : .idle
            }
        } catch {
            textBuffer.flush()
            let message = errorMessage(for: error, kind: provider.kind)
            messages[assistantIndex].text += "\n[错误：\(message)]"
            state = .failed(message)
        }
        // 流式结束后把助手最终文本与工具调用写回记录。
        finalize(assistantRecord, text: messages[assistantIndex].text,
                 toolCalls: messages[assistantIndex].toolCalls, in: session)
        // 本轮结算回 idle 时，逐条冲掉队列（.awaitingApproval/.failed 不冲）。
        if state == .idle { await flushNextQueued() }
    }

    // MARK: - 工具调用：批准 / 跳过 / 执行 / 续轮

    /// 批准并执行某条工具调用；全部 resolved 后自动续轮。
    func approveAndRun(id: String) async {
        // 仅在「待批准」态放行：流式（.streaming）/ 执行中（.running）期间，视图可能
        // 已渲染出 pending 卡片，但状态机仍在飞行；此时点击会重入并并发起第二轮
        // streamAssistantTurn，打乱消息顺序与状态。门禁 state 即可挡住。
        guard state == .awaitingApproval else { return }
        guard let exec = executor,
              let (mi, ci) = locate(id) else { return }
        guard messages[mi].toolCalls[ci].status == .pending else { return }
        messages[mi].toolCalls[ci].status = .running
        state = .running
        do {
            let r = try await exec.run(messages[mi].toolCalls[ci].command)
            messages[mi].toolCalls[ci].status = .done
            messages[mi].toolCalls[ci].output = r.output
            messages[mi].toolCalls[ci].exitCode = r.exitCode
        } catch {
            messages[mi].toolCalls[ci].status = .failed
            messages[mi].toolCalls[ci].output = error.localizedDescription
        }
        persistToolCalls(at: mi)
        await continueIfResolved(messageIndex: mi)
    }

    /// 跳过某条工具调用；全部 resolved 后自动续轮。
    func skip(id: String) async {
        // 同 approveAndRun：仅「待批准」态放行，挡住流式/执行中期间的重入。
        guard state == .awaitingApproval else { return }
        guard let (mi, ci) = locate(id) else { return }
        guard messages[mi].toolCalls[ci].status == .pending else { return }
        messages[mi].toolCalls[ci].status = .skipped
        persistToolCalls(at: mi)
        await continueIfResolved(messageIndex: mi)
    }

    /// 在所有消息里定位某工具调用 id → (消息下标, 调用下标)。
    private func locate(_ id: String) -> (Int, Int)? {
        for (mi, m) in messages.enumerated() {
            if let ci = m.toolCalls.firstIndex(where: { $0.id == id }) { return (mi, ci) }
        }
        return nil
    }

    /// 该消息的工具调用若仍有未决（pending/running）则停在待确认；否则自动续轮。
    private func continueIfResolved(messageIndex mi: Int) async {
        let unresolved = messages[mi].toolCalls.contains {
            $0.status == .pending || $0.status == .running
        }
        if unresolved { state = .awaitingApproval; return }
        await continueAfterTools(serverContext: lastServerContext)
    }

    /// 工具结果已并入会话后再起一轮：复用流式实现（不追加新用户消息）。
    private func continueAfterTools(serverContext: String) async {
        guard let ctx = resolvedTurnContext() else { return }
        await streamAssistantTurn(provider: ctx.provider, key: ctx.key, baseURL: ctx.baseURL,
                                  serverContext: serverContext, session: currentSession)
    }

    // MARK: - 队列消息

    /// 入队一条待发消息（trim 后非空才入队）。
    func enqueue(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        queuedMessages.append(QueuedMessage(text: trimmed))
    }

    /// 移除一条排队消息。
    func removeQueued(id: UUID) {
        queuedMessages.removeAll { $0.id == id }
    }

    /// 把某条排队消息载回输入框编辑（草稿非空则前置追加），并出队。
    func loadQueuedForEditing(id: UUID) {
        guard let item = queuedMessages.first(where: { $0.id == id }) else { return }
        let draft = input.trimmingCharacters(in: .whitespacesAndNewlines)
        input = draft.isEmpty ? item.text : item.text + "\n\n" + draft
        removeQueued(id: id)
    }

    /// 弹出队首消息派发为新一轮（逐条依次）。仅在结算回 idle 时调用。
    /// 经 dispatch→streamAssistantTurn→flushNextQueued 递归，深度 = 队列长度（有界）。
    private func flushNextQueued() async {
        guard state == .idle, !queuedMessages.isEmpty else { return }
        let next = queuedMessages.removeFirst()
        await dispatch(prompt: next.text, serverContext: lastServerContext)
    }

    // MARK: - 编辑 + 分叉重生

    /// 编辑某条用户消息并从该处分叉重生：截断其后全部内容（含助手回复/工具调用），
    /// 用新文本重发并重新生成。仅空闲/失败态可用（忙碌时由调用方禁用入口）。
    func editAndResend(id: UUID, newText: String, serverContext: String) async {
        guard !isBusy else { return }
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let index = messages.firstIndex(where: { $0.id == id }),
              messages[index].role == .user else { return }
        guard let ctx = resolvedTurnContext() else { return }

        lastServerContext = serverContext
        // 注意：不清空 queuedMessages——编辑分叉仍在同一会话内，已排队的待发消息
        // 在重生轮结算回 idle 后照常逐条派发（队列仅在切换/新建/恢复会话时清空）。
        editingMessageID = nil

        // 持久化：删除该消息及其之后的记录。
        let droppedIDs = messages[index...].map(\.id)
        deleteRecords(ids: droppedIDs)

        // 内存：截断到该消息之前，再追加编辑后的用户消息（保留原 id 稳序）。
        let edited = ChatMessage(id: id, role: .user, text: trimmed)
        messages = Array(messages.prefix(index))
        messages.append(edited)

        let session = currentSession
        persist(edited, in: session)
        if index == 0, let session {            // 首条决定标题 → 重派生
            session.title = Self.deriveTitle(from: trimmed)
            try? modelContext?.save()
        }
        await streamAssistantTurn(provider: ctx.provider, key: ctx.key, baseURL: ctx.baseURL,
                                  serverContext: serverContext, session: session)
    }

    // MARK: - 「猜你想问」动态追问

    /// 刷新追问气泡：取消上一次未完成生成，按当前对话重新生成。仅当最后一条是助手时
    /// 有意义（否则清空）。「换一批」与「回复落定」均调用此入口。
    func refreshFollowUps(serverContext: String) {
        followUpTask?.cancel()
        guard messages.last?.role == .assistant else {
            followUps = []; followUpsLoading = false; return
        }
        followUps = []
        followUpsLoading = true
        let snapshot = messages
        followUpTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.generateFollowUps(from: snapshot, serverContext: serverContext)
            if Task.isCancelled { return }
            self.followUps = result
            self.followUpsLoading = false
        }
    }

    /// 清空追问（新消息 / 新会话时调用）。
    private func clearFollowUps() {
        followUpTask?.cancel()
        followUpTask = nil
        followUps = []
        followUpsLoading = false
    }

    /// 生成追问：优先 LLM（复用现有 client，单轮收集文本），失败 / 离线回退启发式。
    private func generateFollowUps(from msgs: [ChatMessage], serverContext: String) async -> [String] {
        if let llm = await llmFollowUps(from: msgs, serverContext: serverContext), !llm.isEmpty {
            return Array(llm.prefix(3))
        }
        return Self.heuristicFollowUps(msgs)
    }

    /// 调一次 LLM 让其产出 3 条追问的 JSON 数组。**不动 `state`**（与正轮解耦）：
    /// 缺 provider/key 或解析失败均回退 nil → 上层走启发式。
    private func llmFollowUps(from msgs: [ChatMessage], serverContext: String) async -> [String]? {
        guard let provider = activeProvider,
              let key = keyOverride ?? keychain.load(for: provider.id),
              let baseURL = resolveBaseURL(for: provider) else { return nil }
        let recent = msgs.suffix(5).map { m -> String in
            let who = m.role == .user ? "用户" : "Agent"
            let body = m.text.isEmpty
                ? (m.toolCalls.first.map { "给出命令：\($0.command)" } ?? "")
                : m.text
            return "\(who)：\(body.prefix(200))"
        }.joined(separator: "\n")
        var system = "你是 SSH 运维终端 uTerm 的助手。"
        if !serverContext.isEmpty { system += "\n当前上下文：\(serverContext)" }
        let user = """
        基于以下对话，猜测用户接下来最可能想问的 3 条追问。要求：贴合当前运维场景、\
        每条不超过 12 个汉字、口语化、可直接作为下一句输入。只输出 JSON 字符串数组，不要任何解释。

        对话：
        \(recent)
        """
        var config = LLMRequestConfig(model: provider.model, baseURL: baseURL, apiKey: key)
        config.tools = []
        config.streamIdleTimeout = streamIdleTimeout
        let client = clientOverride ?? LLMClientFactory.make(for: provider)
        var acc = ""
        do {
            let events = withIdleTimeout(client.stream(
                messages: [ChatMessage(role: .user, text: user)],
                system: system, config: config),
                timeout: config.streamIdleTimeout)
            for try await event in events {
                if Task.isCancelled { return nil }
                if case .text(let delta) = event { acc += delta }
            }
        } catch {
            return nil
        }
        return Self.parseJSONArray(acc)
    }

    /// 从模型输出里抠出第一个 JSON 字符串数组（容忍前后说明 / ``` 包裹）。
    nonisolated static func parseJSONArray(_ raw: String) -> [String]? {
        guard let start = raw.firstIndex(of: "["),
              let end = raw.lastIndex(of: "]"), start < end else { return nil }
        let slice = String(raw[start...end])
        guard let data = slice.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return nil }
        let out = arr.compactMap { $0 as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return out.isEmpty ? nil : out
    }

    /// 启发式回退：读最近对话的关键词 + 命令卡状态路由到追问池，去重取前 3。
    /// 镜像原型 `followUpHeuristic`（去掉我们暂无的 plan/diff 卡分支）。
    nonisolated static func heuristicFollowUps(_ msgs: [ChatMessage]) -> [String] {
        let recent = Array(msgs.suffix(4))
        let blob = recent.map { m -> String in
            m.text.isEmpty
                ? m.toolCalls.map { ($0.explanation ?? "") + " " + $0.command }.joined(separator: " ")
                : m.text
        }.joined(separator: "  ")
        func has(_ pattern: String) -> Bool {
            blob.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
        var pools: [String] = []
        let hasPending = recent.contains { $0.toolCalls.contains { $0.status == .pending } }
        let hasDone = recent.contains { $0.toolCalls.contains { $0.status == .done } }
        if hasPending { pools += ["先看看会影响什么", "执行后怎么验证"] }
        if hasDone { pools += ["解释下这段输出", "导出结果到文件"] }
        if has("磁盘|disk|分区|docker|/var/log|日志|清理") { pools += ["还有哪些大文件", "清理后还剩多少空间", "设置磁盘告警阈值"] }
        if has("内存|mem|oom") { pools += ["哪个进程最吃内存", "要不要加 swap"] }
        if has("cpu|负载|load") { pools += ["看看是哪个进程", "近一小时负载曲线"] }
        if has("nginx|502|upstream|gzip|keepalive|反向代理") { pools += ["看 nginx 错误日志", "压测健康检查", "加上访问限流"] }
        if has("重启|restart|部署|deploy|回滚|reload") { pools += ["确认服务已起来", "看看启动日志", "回滚到上一版本"] }
        pools += ["当前服务器健康度", "列出最近的告警", "生成一份巡检报告"]

        var seen = Set<String>()
        var out: [String] = []
        for s in pools where !seen.contains(s) {
            seen.insert(s); out.append(s)
            if out.count >= 3 { break }
        }
        return out
    }

    // MARK: - 持久化（modelContext 为 nil 时全部 no-op）

    /// 取当前会话；无则惰性创建并插入。返回 nil 表示纯内存模式。
    private func ensureSession(firstPrompt: String) -> ChatSession? {
        guard let ctx = modelContext else { return nil }
        if let s = currentSession { return s }
        let s = ChatSession(title: Self.deriveTitle(from: firstPrompt))
        ctx.insert(s)
        currentSession = s
        return s
    }

    @discardableResult
    private func persist(_ message: ChatMessage, in session: ChatSession?) -> ChatMessageRecord? {
        guard let ctx = modelContext, let session else { return nil }
        let record = ChatMessageRecord(role: message.role, text: message.text,
                                       toolCalls: message.toolCalls,
                                       id: message.id, createdAt: Date())
        record.session = session
        ctx.insert(record)
        session.updatedAt = Date()
        try? ctx.save()
        return record
    }

    private func finalize(_ record: ChatMessageRecord?, text: String,
                          toolCalls: [ToolCallState], in session: ChatSession?) {
        guard let ctx = modelContext, let record else { return }
        record.text = text
        record.toolCalls = toolCalls
        session?.updatedAt = Date()
        try? ctx.save()
    }

    /// 把某条消息当前的工具调用状态写回其持久化记录（批准/跳过/执行后）。
    private func persistToolCalls(at messageIndex: Int) {
        guard let ctx = modelContext, let session = currentSession,
              messages.indices.contains(messageIndex) else { return }
        let message = messages[messageIndex]
        guard let record = session.orderedMessages.first(where: { $0.id == message.id })
        else { return }
        record.toolCalls = message.toolCalls
        session.updatedAt = Date()
        try? ctx.save()
    }

    /// 删除当前会话中匹配 ids 的记录（纯内存模式 no-op）。
    private func deleteRecords(ids: [UUID]) {
        guard let ctx = modelContext, let session = currentSession else { return }
        let set = Set(ids)
        for record in session.orderedMessages where set.contains(record.id) {
            ctx.delete(record)
        }
        session.updatedAt = Date()
        try? ctx.save()
    }

    private func resolvePendingRestoredSessionIfNeeded() {
        guard let sessionID = pendingRestoredSessionID,
              let ctx = modelContext
        else { return }
        pendingRestoredSessionID = nil
        var descriptor = FetchDescriptor<ChatSession>(
            predicate: #Predicate { $0.id == sessionID })
        descriptor.fetchLimit = 1
        guard let session = try? ctx.fetch(descriptor).first else { return }
        load(session)
    }

    private func resolveBaseURL(for provider: AIProvider) -> URL? {
        switch ProviderEndpointPolicy.resolve(configuredBaseURL: provider.baseURL,
                                              kind: provider.kind) {
        case .success(let url):
            return url
        case .failure:
            return nil
        }
    }

    private func errorMessage(for error: Error, kind: ProviderKind) -> String {
        guard let e = error as? LLMClientError else {
            return error.localizedDescription
        }
        switch e {
        case .httpError(let status, let body):
            if status == 401 {
                switch kind {
                case .anthropic: return "Anthropic API Key 无效，请到 Settings 检查密钥。"
                case .openai:    return "OpenAI API Key 无效，请到 Settings 检查密钥。"
                }
            }
            return "请求失败（HTTP \(status)）：\(body)"
        case .invalidResponse:
            return "服务器返回了无法解析的响应。"
        case .streamIdleTimeout:
            return "响应流长时间没有新输出，已停止等待；请重试。"
        }
    }

    private static func systemPrompt(serverContext: String) -> String {
        var s = "你是 uTerm（一个 macOS 原生 SSH 终端应用）内置的服务器工作台助手，"
            + "帮助用户处理服务器运维与命令行问题。简洁、准确地回答。"
        if !serverContext.isEmpty {
            s += "\n\n当前上下文：\(serverContext)"
        }
        return s
    }
}

/// 将高频 SSE 文本碎片合并成低频 UI 发布。与只在下一事件到达时检查时钟的 accumulator
/// 不同，本 buffer 会真实启动定时任务：provider 发完一批后即使保持连接静默，尾片也会
/// 在窗口截止时发布，不会一直扣到 EOF / 下一事件。
@MainActor
final class StreamingTextBuffer {
    static let publishInterval: Duration = .milliseconds(50)

    private let publishInterval: Duration
    private let publish: (String) -> Void
    private var pending = ""
    private var lastPublication: ContinuousClock.Instant?
    private var pendingFlush: Task<Void, Never>?

    init(
        publishInterval: Duration = StreamingTextBuffer.publishInterval,
        publish: @escaping (String) -> Void
    ) {
        self.publishInterval = publishInterval
        self.publish = publish
    }

    func append(_ delta: String, at now: ContinuousClock.Instant = .now) {
        guard !delta.isEmpty else { return }
        pending += delta

        guard let lastPublication else {
            publishPending(at: now)
            return
        }
        let elapsed = lastPublication.duration(to: now)
        if elapsed >= publishInterval {
            pendingFlush?.cancel()
            pendingFlush = nil
            publishPending(at: now)
        } else if pendingFlush == nil {
            scheduleFlush(after: publishInterval - elapsed)
        }
    }

    func flush() {
        pendingFlush?.cancel()
        pendingFlush = nil
        publishPending(at: .now)
    }

    private func scheduleFlush(after delay: Duration) {
        pendingFlush = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.pendingFlush = nil
            self.publishPending(at: .now)
        }
    }

    private func publishPending(at now: ContinuousClock.Instant) {
        guard !pending.isEmpty else { return }
        let text = pending
        pending = ""
        lastPublication = now
        publish(text)
    }
}
