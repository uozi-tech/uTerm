import AgentKit
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
    /// 待发队列：Agent 忙碌时提交的消息。普通的等整轮结束后逐条派发；标成「下一步送达」
    /// 的在当前这步工具跑完后并入会话，不打断在途回复。纯内存；规则在 AgentKit。
    private var queue = AgentMessageQueue()
    var queuedMessages: [QueuedMessage] { queue.items }
    /// 当前处于内联编辑态的用户消息 id（视图驱动；会话切换时清空）。
    var editingMessageID: UUID?
    var input: String = ""
    private(set) var state: State = .idle {
        didSet {
            if state == .awaitingApproval { scheduleAutomaticApproval() }
            else { cancelAutomaticApproval() }
        }
    }
    var approvalMode: AgentSafety = .confirm {
        didSet {
            guard approvalMode != oldValue else { return }
            cancelAutomaticApproval()
            scheduleAutomaticApproval()
        }
    }
    private(set) var reviewingToolCallID: String?
    @ObservationIgnored private var approvalTask: Task<Void, Never>?
    @ObservationIgnored private var approvalReviewID: UUID?
    private(set) var turnWasStopped = false

    var canStop: Bool {
        // 必须先读 `state`：`activeStream` / `activeOperationID` 不参与观察，`||` 又会短路 ——
        // 流式期间读到 `activeStream != nil` 就返回的话，视图对 `state` 没有任何依赖，
        // 回复结束时不会重绘，「停止对话」按钮就残留在屏上且点了没反应。这两个字段的每次
        // 变化都伴随 `state` 或 `turnWasStopped` 的写入，所以挂上 `state` 就够了。
        let state = self.state
        return activeStream != nil || activeOperationID != nil || state == .awaitingApproval
    }

    /// Stops the conversation driver, not an already-dispatched remote process.
    func stop() {
        guard canStop else { return }
        cancelAutomaticApproval()
        let stream = activeStream
        stream?.buffer?.flush()
        stream?.buffer?.cancel()
        if let stream { persistStream(stream) }
        // Revoke ownership synchronously before cancellation can resume old tasks.
        // Keep generation/scope so in-flight command results still reach this session.
        activeOperationID = nil
        activeStream = nil
        stream?.task?.cancel()
        queue.removeAll()
        for mi in messages.indices {
            for ci in messages[mi].toolCalls.indices where messages[mi].toolCalls[ci].status == .pending {
                messages[mi].toolCalls[ci].status = .skipped
                messages[mi].toolCalls[ci].output = String(localized: "用户已停止本轮对话，命令未执行。")
            }
            persistToolCalls(messageID: messages[mi].id, sessionID: currentSession?.id)
        }
        turnWasStopped = true
        settleVisibleState()
    }

    /// 命令执行器；nil 时不向模型暴露工具，行为退化为纯文本对话（旧版）。
    /// 由工作区在 SSH 连接建立后注入；断连时置 nil。
    var executor: CommandExecutor? {
        didSet {
            commandScope = UUID()
            cancelAutomaticApproval()
        }
    }

    /// 一条远端命令执行尝试结束后的通知。命令可能通过重定向、sed 等任意 shell
    /// 语法改动文件，无法可靠地从命令文本推断写集；工作区据此刷新目录与已打开文件。
    /// 即使执行器抛错也要通知——远端可能已经完成了部分写入，只是回包时断线。
    @ObservationIgnored var onCommandExecutionFinished: (@MainActor () async -> Void)?

    /// 测试可缩短；生产默认 60 秒无文本 / 工具事件即结束静默 SSE。
    @ObservationIgnored var streamIdleTimeout: Duration = .seconds(60)

    /// 最近一次 `send` 携带的 serverContext，供工具续轮复用 system prompt。
    @ObservationIgnored private var lastServerContext = ""
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var commandScope = UUID()
    @ObservationIgnored private var activeOperationID: UUID?
    @ObservationIgnored private var activeStream: StreamOperation?
    @ObservationIgnored private var commands: [UUID: CommandOperation] = [:]
    @ObservationIgnored private var isDisposed = false
    @ObservationIgnored private var lastTurnContext: TurnContext?

    /// Values are captured before suspending; changing providers cannot retarget a running turn.
    private struct TurnContext {
        var config: LLMRequestConfig
        let kind: ProviderKind
        let client: LLMClient
    }

    private final class StreamOperation {
        let id = UUID()
        let generation: UUID
        let sessionID: UUID?
        var message: ChatMessage
        var finalState: State = .idle
        var buffer: StreamingTextBuffer?
        var task: Task<Void, Never>?

        init(generation: UUID, sessionID: UUID?, message: ChatMessage) {
            self.generation = generation
            self.sessionID = sessionID
            self.message = message
        }
    }

    private struct CommandOperation {
        let id: UUID
        let generation: UUID
        let scope: UUID
        let sessionID: UUID?
        let messageID: UUID
        let callID: String
    }

    /// 持久化上下文；nil 时纯内存（单测路径）。由视图 `attach(context:)` 注入。
    var modelContext: ModelContext?
    /// 当前会话；首次发送时惰性创建，避免空会话污染历史。
    private(set) var currentSession: ChatSession?
    /// workspace 快照可能先于 SwiftData context 恢复；context 注入后再解析。
    @ObservationIgnored private var pendingRestoredSessionID: UUID?

    /// 顶栏展示的会话标题。
    var sessionTitle: String {
        currentSession?.displayTitle ?? String(localized: "新对话")
    }

    /// 全部已配置的 provider（外部灌入，按 sortOrder）。
    var providers: [AIProvider] = []
    /// 当前活动 provider id；nil 或失效时 fallback 到 sortOrder 最小者。
    var activeProviderID: UUID?

    /// 当前活动 provider；providers 空则 nil。
    var activeProvider: AIProvider? {
        AIProvider.active(in: providers, id: activeProviderID)
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
        leaveSession()
        pendingRestoredSessionID = nil
        currentSession = nil
        messages = []
    }

    /// 切换到历史会话，载入其消息。
    func load(_ session: ChatSession) {
        guard !isDisposed else { return }
        guard session.id != currentSession?.id else { return }
        leaveSession()
        pendingRestoredSessionID = nil
        currentSession = session
        messages = session.orderedMessages.map(\.asChatMessage)
        // A process may have exited while a command was running. Never offer to run it again
        // merely because its result was not recorded.
        for mi in messages.indices {
            for ci in messages[mi].toolCalls.indices where messages[mi].toolCalls[ci].status == .running {
                let messageID = messages[mi].id
                let callID = messages[mi].toolCalls[ci].id
                let live = commands.values.contains {
                    $0.sessionID == session.id && $0.messageID == messageID && $0.callID == callID
                }
                if !live {
                    messages[mi].toolCalls[ci].status = .failed
                    messages[mi].toolCalls[ci].output = String(localized: "上次命令的执行结果未知，先核实主机状态。")
                    // This model cannot observe the execution. Keep the durable record intact:
                    // another window may still own the command and save its actual result.
                }
            }
        }
        settleVisibleState()
    }

    func snapshot() -> AgentSnapshot {
        AgentSnapshot(currentSessionID: currentSession?.id, input: input)
    }

    func restore(from snapshot: AgentSnapshot?) {
        leaveSession()
        commandScope = UUID()
        guard let snapshot else {
            pendingRestoredSessionID = nil
            currentSession = nil
            messages = []
            queue.removeAll()
            editingMessageID = nil
            input = ""
            if case .failed = state { state = .idle }
            return
        }

        input = snapshot.input
        pendingRestoredSessionID = snapshot.currentSessionID
        currentSession = nil
        messages = []
        queue.removeAll()
        editingMessageID = nil
        if case .failed = state { state = .idle }
        resolvePendingRestoredSessionIfNeeded()
    }

    /// Invalidate ownership before a new session can submit. Commands already sent to SSH
    /// retain their result handling, but lose permission to continue the conversation.
    private func leaveSession() {
        cancelAutomaticApproval()
        turnWasStopped = false
        if let stream = activeStream {
            stream.buffer?.flush()
            persistStream(stream)
            stream.buffer?.cancel()
            stream.task?.cancel()
        }
        generation = UUID()
        activeOperationID = nil
        activeStream = nil
        queue.removeAll()
        editingMessageID = nil
        lastServerContext = ""
        lastTurnContext = nil
        state = .idle
    }

    func dispose() {
        leaveSession()
        isDisposed = true
        commandScope = UUID()
        onCommandExecutionFinished = nil
        executor = nil
    }

    private func owns(_ id: UUID, generation expected: UUID) -> Bool {
        !isDisposed && generation == expected && activeOperationID == id
    }

    private func settleVisibleState() {
        let calls = messages.flatMap(\.toolCalls)
        state = calls.contains { $0.status == .running } ? .running
            : calls.contains { $0.status == .pending } ? .awaitingApproval : .idle
    }

    /// 从首句话派生会话标题（单行、限长）。算法现由 `AgentKit.AgentTitle`
    /// 统一实现（与 uTable `AgentChatStore.deriveTitle` 同一份逻辑）。
    nonisolated static func deriveTitle(from prompt: String) -> String {
        AgentTitle.derive(from: prompt)
    }

    private let keychain: AgentKeychain
    /// 测试注入。非 nil 时绕过工厂直接用此 client。
    private let clientOverride: LLMClient?
    /// 测试注入。非 nil 时绕过 keychain。
    private let keyOverride: String?

    /// 用户为各模型挑的思考深度；nil = 一律不带思考参数（单测构造走这条，不读本机偏好）。
    @ObservationIgnored var reasoningPreferences: AgentReasoningPreferences? = .shared

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
        self.reasoningPreferences = nil
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
    /// - Parameter delivery: 只在忙碌时有意义 —— 排到整轮结束（缺省），还是下一步就送达。
    func submit(text: String, serverContext: String,
                delivery: QueuedMessage.Delivery = .afterTurn) async {
        guard !isDisposed, !Task.isCancelled else { return }
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        if isBusy {
            enqueue(prompt, delivery: delivery)
        } else {
            await dispatch(prompts: [prompt], serverContext: serverContext)
        }
    }

    /// 兼容旧调用方/测试：等价于 submit。
    func send(serverContext: String) async {
        await submit(serverContext: serverContext)
    }

    /// 发起新一轮：校验凭据 → 追加用户消息 → 落库 → 流式。通常只有一条；排队里攒了几条
    /// 「下一步送达」却没等到下一步时，它们一起开这一轮。
    private func dispatch(prompts: [String], serverContext: String) async {
        guard !isDisposed, !Task.isCancelled, let first = prompts.first else { return }
        guard let ctx = resolvedTurnContext() else { return }
        turnWasStopped = false
        lastTurnContext = ctx
        lastServerContext = serverContext
        let session = ensureSession(firstPrompt: first)
        for prompt in prompts {
            let userMessage = ChatMessage(role: .user, text: prompt)
            messages.append(userMessage)
            persist(userMessage, in: session)
        }
        await streamAssistantTurn(context: ctx, serverContext: serverContext, sessionID: session?.id)
    }

    /// provider/key/baseURL 校验；任一缺失置 .failed 并返回 nil。
    private func resolvedTurnContext() -> TurnContext? {
        guard let provider = activeProvider else {
            state = .failed(String(localized: "尚未配置模型服务")); return nil
        }
        guard !provider.model.isEmpty else {
            state = .failed(String(localized: "还没有选择模型：在输入区左下角的模型菜单里选一个")); return nil
        }
        guard let key = keyOverride ?? keychain.load(for: provider.id) else {
            state = .failed(String(localized: "所选模型服务缺少 API Key")); return nil
        }
        guard let baseURL = resolveBaseURL(for: provider) else {
            state = .failed(String(localized: "所选模型服务的 Base URL 无效或不安全")); return nil
        }
        var config = LLMRequestConfig(model: provider.model, baseURL: baseURL, apiKey: key)
        config.tools = executor != nil ? [.runCommand] : []
        config.streamIdleTimeout = streamIdleTimeout
        config.reasoning = reasoningPreferences?.request(
            providerID: provider.id, protocol: provider.kind.wireProtocol, model: provider.model)
        return TurnContext(config: config, kind: provider.kind,
                           client: clientOverride ?? LLMClientFactory.make(for: provider))
    }

    /// 一轮助手流式：追加空 assistant 消息 → 落库 → 流式消费 `LLMEvent`
    /// （文本累加、工具调用追加为 pending 卡片）→ 依据是否有 pending 决定终态。
    /// `send` 与工具续轮（`continueAfterTools`）共用此实现。
    private func streamAssistantTurn(context: TurnContext, serverContext: String, sessionID: UUID?) async {
        guard !isDisposed, !Task.isCancelled else { return }
        // 出站上下文自动压缩：内存与聊天记录保留全文，超预算的历史在发送
        // 副本上折叠旧命令输出 / 省略最旧轮次（ContextCompressor 注释详述）。
        let conversation = ContextCompressor.compress(messages)
        let assistantMessage = ChatMessage(role: .assistant, text: "")
        messages.append(assistantMessage)
        persist(assistantMessage, in: currentSession)
        let operation = StreamOperation(generation: generation, sessionID: sessionID, message: assistantMessage)
        activeStream = operation
        activeOperationID = operation.id
        state = .streaming
        let system = Self.systemPrompt(serverContext: serverContext)
        operation.buffer = StreamingTextBuffer { [weak self, weak operation] text in
            guard let self, let operation,
                  self.owns(operation.id, generation: operation.generation) else { return }
            operation.message.text += text
            self.publishStream(operation)
        }
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.consumeStream(operation, context: context, conversation: conversation, system: system)
        }
        operation.task = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: { task.cancel() }
        guard owns(operation.id, generation: operation.generation) else { return }
        operation.buffer?.flush()
        operation.buffer?.cancel()
        persistStream(operation)
        activeStream = nil
        activeOperationID = nil
        // Publish the terminal state only after saving the reply and releasing ownership.
        // Otherwise a newly submitted turn could overtake this driver's task resumption.
        state = Task.isCancelled ? .idle : operation.finalState
        if Task.isCancelled { return }
        if !isBusy { await flushNextQueued() }
    }

    private func publishStream(_ operation: StreamOperation) {
        guard owns(operation.id, generation: operation.generation),
              let index = messages.firstIndex(where: { $0.id == operation.message.id }) else { return }
        messages[index] = operation.message
    }

    private func consumeStream(_ operation: StreamOperation, context: TurnContext,
                               conversation: [ChatMessage], system: String) async {
        guard owns(operation.id, generation: operation.generation), !Task.isCancelled else { return }
        do {
            let events = context.client.streamWithIdleTimeout(
                messages: conversation, system: system, config: context.config)
            for try await event in events {
                guard owns(operation.id, generation: operation.generation), !Task.isCancelled else { return }
                switch event {
                case .text(let delta):
                    operation.buffer?.append(delta)
                case .toolCall(let call):
                    operation.buffer?.flush()
                    operation.message.toolCalls.append(ToolCallState(from: call))
                    publishStream(operation)
                case .thinking(let block):
                    operation.message.thinking.append(block)
                }
            }
            guard owns(operation.id, generation: operation.generation), !Task.isCancelled else { return }
            operation.buffer?.flush()
            let toolCalls = operation.message.toolCalls
            let visibleText = operation.message.text
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if visibleText.isEmpty && toolCalls.isEmpty {
                let message = String(localized: "模型未返回任何内容")
                operation.message.text = Self.inlineErrorText(message)
                operation.finalState = .failed(message)
            } else {
                let pending = toolCalls.contains { $0.status == .pending }
                operation.finalState = pending ? .awaitingApproval : .idle
            }
        } catch {
            guard owns(operation.id, generation: operation.generation), !Task.isCancelled else { return }
            operation.buffer?.flush()
            let message = errorMessage(for: error, kind: context.kind)
            operation.message.text += "\n" + Self.inlineErrorText(message)
            operation.finalState = .failed(message)
        }
        publishStream(operation)
    }

    // MARK: - 独立 AI 审批

    func approvalSummary(for call: ToolCallState) -> String? {
        if reviewingToolCallID == call.id { return String(localized: "AI 正在审批，仍可手动运行或跳过") }
        guard let reason = call.approvalReason else { return nil }
        switch call.approvedByAI {
        case true?: return String(localized: "AI 已批准：\(reason)")
        case false?: return String(localized: "需人工确认：\(reason)")
        case nil: return reason   // 规则直接放行的只读命令，没有经过 AI
        }
    }

    private func cancelAutomaticApproval() {
        approvalReviewID = nil
        reviewingToolCallID = nil
        approvalTask?.cancel()
        approvalTask = nil
    }

    private func scheduleAutomaticApproval() {
        guard !isDisposed, state == .awaitingApproval, approvalMode != .confirm,
              approvalTask == nil, executor != nil,
              let message = messages.first(where: { $0.toolCalls.contains { $0.status == .pending } }),
              let call = message.toolCalls.first(where: { $0.status == .pending }),
              call.approvalReason == nil else { return }
        let reviewID = UUID()
        let expectedGeneration = generation
        let expectedScope = commandScope
        let expectedMode = approvalMode
        let request = AgentToolApproval.Request(
            id: reviewID.uuidString, toolName: call.name, command: call.command,
            userIntent: messages.filter { $0.role == .user }.suffix(3).map(\.text).joined(separator: "\n"),
            context: lastServerContext,
            mode: approvalMode == .readAuto ? .readOnly : .standard)
        // 只读命令由规则直接放行：不请 AI，也就不挂「AI 正在审批」。
        let readOnly = AgentToolApproval.isReadOnly(request)
        approvalReviewID = reviewID
        reviewingToolCallID = readOnly ? nil : call.id
        approvalTask = Task { [weak self] in
            guard let self else { return }
            let context = self.lastTurnContext ?? self.resolvedTurnContext()
            let reviewClient = context?.client
            let reviewConfig = context?.config
            let decision = readOnly ? nil : await AgentToolApproval.evaluate(request) { system, prompt in
                guard let reviewClient, let reviewConfig else { throw LLMClientError.invalidResponse }
                return try await reviewToolApproval(client: reviewClient, config: reviewConfig,
                                                    system: system, prompt: prompt)
            }
            guard !Task.isCancelled, !self.isDisposed, self.approvalReviewID == reviewID,
                  self.generation == expectedGeneration, self.commandScope == expectedScope,
                  self.approvalMode == expectedMode, self.state == .awaitingApproval,
                  let (mi, ci) = self.locate(call.id), self.messages[mi].id == message.id,
                  self.messages[mi].toolCalls[ci] == call else { return }
            self.messages[mi].toolCalls[ci].approvalReason = decision?.reason ?? AgentToolApproval.readOnlyReason
            self.messages[mi].toolCalls[ci].approvedByAI = decision?.approved
            self.persistToolCalls(messageID: message.id, sessionID: self.currentSession?.id)
            // Release review ownership before execution changes state, so it cannot
            // cancel its own tool driver. No suspension between recheck and dispatch.
            self.approvalTask = nil
            self.approvalReviewID = nil
            self.reviewingToolCallID = nil
            if decision?.approved ?? true { await self.approveAndRun(id: call.id) }
        }
    }

    // MARK: - 工具调用：批准 / 跳过 / 执行 / 续轮

    /// 批准并执行某条工具调用；全部 resolved 后自动续轮。
    func approveAndRun(id: String) async {
        // 仅在「待批准」态放行：流式（.streaming）/ 执行中（.running）期间，视图可能
        // 已渲染出 pending 卡片，但状态机仍在飞行；此时点击会重入并并发起第二轮
        // streamAssistantTurn，打乱消息顺序与状态。门禁 state 即可挡住。
        guard !isDisposed, !Task.isCancelled, state == .awaitingApproval else { return }
        guard let exec = executor.map(Self.supervised),
              let (mi, ci) = locate(id) else { return }
        guard messages[mi].toolCalls[ci].status == .pending else { return }
        guard let context = lastTurnContext ?? resolvedTurnContext() else { return }
        let operation = CommandOperation(id: UUID(), generation: generation, scope: commandScope,
                                         sessionID: currentSession?.id, messageID: messages[mi].id, callID: id)
        let command = messages[mi].toolCalls[ci].command
        let serverContext = lastServerContext
        let refresh = onCommandExecutionFinished
        commands[operation.id] = operation
        activeOperationID = operation.id
        messages[mi].toolCalls[ci].status = .running
        persistToolCalls(messageID: operation.messageID, sessionID: operation.sessionID)
        state = .running
        // Once sent, do not equate cancelling the UI driver with stopping a remote process.
        let task = Task { () -> Result<CommandResult, Error> in
            do { return .success(try await exec.run(command)) }
            catch { return .failure(error) }
        }
        let result = await task.value
        completeCommand(operation, result: result)
        if !isDisposed, operation.scope == commandScope { await refresh?() }
        commands[operation.id] = nil
        guard owns(operation.id, generation: operation.generation),
              operation.scope == commandScope, !Task.isCancelled else {
            // Returning to the originating session may show this command, but must not
            // resurrect its former automatic tool loop or dispatch a newer queue.
            if isVisible(operation), activeOperationID == nil { settleVisibleState() }
            if owns(operation.id, generation: operation.generation) {
                activeOperationID = nil
                settleVisibleState()
            }
            return
        }
        activeOperationID = nil
        await continueIfResolved(messageID: operation.messageID, context: context, serverContext: serverContext)
    }

    /// 真 SSH 执行器一律放到静默看门狗底下跑；测试替身与已经套过的原样返回。
    /// 在这里套而不是让各入口注入：入口有三处（工作区 / 终端窗口 / iOS），漏一处就是
    /// 一张永远停在「执行中」的卡片。
    nonisolated static func supervised(_ executor: CommandExecutor) -> CommandExecutor {
        (executor as? SSHCommandExecutor).map { SupervisedAgentCommandExecutor($0) } ?? executor
    }

    /// 跳过某条工具调用；全部 resolved 后自动续轮。
    func skip(id: String) async {
        // 同 approveAndRun：仅「待批准」态放行，挡住流式/执行中期间的重入。
        guard !isDisposed, !Task.isCancelled, state == .awaitingApproval else { return }
        cancelAutomaticApproval()
        guard let (mi, ci) = locate(id) else { return }
        guard messages[mi].toolCalls[ci].status == .pending else { return }
        messages[mi].toolCalls[ci].status = .skipped
        let messageID = messages[mi].id
        persistToolCalls(messageID: messageID, sessionID: currentSession?.id)
        await continueIfResolved(messageID: messageID, context: lastTurnContext, serverContext: lastServerContext)
    }

    /// 在所有消息里定位某工具调用 id → (消息下标, 调用下标)。
    private func locate(_ id: String) -> (Int, Int)? {
        for (mi, m) in messages.enumerated() {
            if let ci = m.toolCalls.firstIndex(where: { $0.id == id }) { return (mi, ci) }
        }
        return nil
    }

    /// 该消息的工具调用若仍有未决（pending/running）则停在待确认；否则自动续轮。
    private func continueIfResolved(messageID: UUID, context: TurnContext?, serverContext: String) async {
        guard let mi = messages.firstIndex(where: { $0.id == messageID }) else { state = .idle; return }
        let unresolved = messages[mi].toolCalls.contains {
            $0.status == .pending || $0.status == .running
        }
        if unresolved { state = .awaitingApproval; return }
        deliverNextStepMessages()
        await continueAfterTools(context: context, serverContext: serverContext)
    }

    /// 一步结束、下一次请求之前：把标成「下一步送达」的排队消息并进会话。模型在续轮里
    /// 同时读到工具结果和这几条消息，在途的回复没有被取消过。
    private func deliverNextStepMessages() {
        for item in queue.takeNextStep() {
            var message = ChatMessage(role: .user, text: item.text)
            message.continuesTurn = true
            messages.append(message)
            persist(message, in: currentSession)
        }
    }

    /// 工具结果已并入会话后再起一轮：复用流式实现（不追加新用户消息）。
    private func continueAfterTools(context: TurnContext?, serverContext: String) async {
        guard let ctx = context ?? resolvedTurnContext() else { return }
        await streamAssistantTurn(context: ctx, serverContext: serverContext, sessionID: currentSession?.id)
    }

    // MARK: - 队列消息

    /// 入队一条待发消息（trim 后非空才入队）。
    func enqueue(_ text: String, delivery: QueuedMessage.Delivery = .afterTurn) {
        queue.enqueue(text, delivery: delivery)
    }

    /// 移除一条排队消息。
    func removeQueued(id: UUID) {
        queue.remove(id: id)
    }

    /// 「立即发送」：不打断在途回复，把这条排队消息改成下一步送达。
    func sendQueuedAtNextStep(id: UUID) {
        queue.sendAtNextStep(id: id)
    }

    /// 把某条排队消息载回输入框编辑（草稿非空则前置追加），并出队。
    func loadQueuedForEditing(id: UUID) {
        guard let item = queuedMessages.first(where: { $0.id == id }) else { return }
        let draft = input.trimmingCharacters(in: .whitespacesAndNewlines)
        input = draft.isEmpty ? item.text : item.text + "\n\n" + draft
        removeQueued(id: id)
    }

    /// 取队首派发为新一轮（逐条依次；攒着的「下一步送达」一次取完）。仅在一轮结算回
    /// idle / failed 时调用：失败也要接着派发，否则排队消息卡在条带里，下一条手动发送还会
    /// 插到它们前面。
    /// 经 dispatch→streamAssistantTurn→flushNextQueued 递归，深度 ≤ 队列长度（有界）。
    private func flushNextQueued() async {
        guard !isDisposed, !Task.isCancelled, !isBusy else { return }
        let next = queue.takeNextTurn()
        guard !next.isEmpty else { return }
        await dispatch(prompts: next.map(\.text), serverContext: lastServerContext)
    }

    // MARK: - 编辑 + 分叉重生

    /// 编辑某条用户消息并从该处分叉重生：截断其后全部内容（含助手回复/工具调用），
    /// 用新文本重发并重新生成。仅空闲/失败态可用（忙碌时由调用方禁用入口）。
    func editAndResend(id: UUID, newText: String, serverContext: String) async {
        guard !isDisposed, !Task.isCancelled, !isBusy else { return }
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let index = messages.firstIndex(where: { $0.id == id }),
              messages[index].role == .user else { return }
        guard let ctx = resolvedTurnContext() else { return }

        lastServerContext = serverContext
        lastTurnContext = ctx
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
        await streamAssistantTurn(context: ctx, serverContext: serverContext, sessionID: session?.id)
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
        let record = ChatMessageRecord(roleRaw: message.role.rawValue, text: message.text,
                                       toolCallsJSON: ChatMessageRecord.encode(message.toolCalls),
                                       id: message.id, createdAt: Date())
        record.session = session
        ctx.insert(record)
        session.updatedAt = Date()
        try? ctx.save()
        return record
    }

    /// Re-fetch by identity after suspension; never retain a possibly deleted SwiftData
    /// record or resolve a command against whichever session happens to be visible now.
    private func record(messageID: UUID, sessionID: UUID?) -> ChatMessageRecord? {
        guard let ctx = modelContext, let sessionID else { return nil }
        var descriptor = FetchDescriptor<ChatMessageRecord>(predicate: #Predicate { $0.id == messageID })
        descriptor.fetchLimit = 1
        guard let record = try? ctx.fetch(descriptor).first,
              !record.isDeleted, let session = record.session, !session.isDeleted,
              session.id == sessionID else { return nil }
        return record
    }

    private func persistStream(_ operation: StreamOperation) {
        guard let record = record(messageID: operation.message.id, sessionID: operation.sessionID) else { return }
        record.text = operation.message.text
        record.toolCalls = operation.message.toolCalls
        record.session?.updatedAt = Date()
        try? modelContext?.save()
    }

    private func persistToolCalls(messageID: UUID, sessionID: UUID?) {
        guard let message = messages.first(where: { $0.id == messageID }),
              let record = record(messageID: messageID, sessionID: sessionID) else { return }
        record.toolCalls = message.toolCalls
        record.session?.updatedAt = Date()
        try? modelContext?.save()
    }

    private func isVisible(_ operation: CommandOperation) -> Bool {
        guard !isDisposed else { return false }
        if let sessionID = operation.sessionID { return currentSession?.id == sessionID }
        return generation == operation.generation
    }

    private func completeCommand(_ operation: CommandOperation, result: Result<CommandResult, Error>) {
        func update(_ call: inout ToolCallState) {
            switch result {
            case .success(let value):
                call.status = .done
                call.output = value.output
                call.exitCode = value.exitCode
            case .failure(let error):
                call.status = .failed
                call.output = error.localizedDescription
            }
        }
        if let record = record(messageID: operation.messageID, sessionID: operation.sessionID) {
            var calls = record.toolCalls
            if let ci = calls.firstIndex(where: { $0.id == operation.callID }) {
                update(&calls[ci])
                record.toolCalls = calls
                record.session?.updatedAt = Date()
                try? modelContext?.save()
            }
        }
        if isVisible(operation), let mi = messages.firstIndex(where: { $0.id == operation.messageID }),
           let ci = messages[mi].toolCalls.firstIndex(where: { $0.id == operation.callID }) {
            update(&messages[mi].toolCalls[ci])
        }
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
                case .anthropic: return String(localized: "Anthropic API Key 无效，到「设置 › 模型服务」检查 API Key。")
                case .openai:    return String(localized: "OpenAI API Key 无效，到「设置 › 模型服务」检查 API Key。")
                }
            }
            return String(localized: "请求失败（HTTP \(String(status))）：\(body)")
        case .invalidResponse:
            return String(localized: "模型服务返回了无法解析的响应。")
        case .streamIdleTimeout:
            return String(localized: "响应流长时间没有新输出，已停止等待，可以重试。")
        case .streamError(let detail):
            return String(localized: "模型服务中途报错，回复不完整：\(detail)")
        case .incompleteStream:
            return String(localized: "连接在回复说完之前断开，上面的内容不完整；可发送「继续」让它接着说。")
        case .outputLimitReached:
            return String(localized: "回复达到单次输出上限被截断；可发送「继续」让它接着说。")
        }
    }

    /// 内联在助手消息末尾的错误文字（「[错误：…]」）。
    nonisolated static func inlineErrorText(_ message: String) -> String {
        String(localized: "[错误：\(message)]", comment: "内联在 Agent 回复末尾的错误")
    }

    /// `inlineErrorText` 插值之前的那段开头，用来认出末条气泡里已经内联了错误。
    nonisolated static var inlineErrorPrefix: String {
        let sentinel = "\u{1}"
        return inlineErrorText(sentinel).components(separatedBy: sentinel).first ?? ""
    }

    private static func systemPrompt(serverContext: String) -> String {
        var s = "你是 uTerm（一个 macOS 原生 SSH 终端应用）内置的服务器工作台助手，"
            + "帮助用户处理服务器运维与命令行问题。简洁、准确地回答。"
            + "用用户提问所用的语言回答；拿不准时用\(AgentReplyLanguage.displayName)。"
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

    func cancel() {
        pendingFlush?.cancel()
        pendingFlush = nil
        pending = ""
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
