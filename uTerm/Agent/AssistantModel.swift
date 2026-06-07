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
    var input: String = ""
    private(set) var state: State = .idle

    /// 命令执行器；nil 时不向模型暴露工具，行为退化为纯文本对话（旧版）。
    /// 由工作区在 SSH 连接建立后注入；断连时置 nil。
    var executor: CommandExecutor?

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
        if case .failed = state { state = .idle }
    }

    /// 切换到历史会话，载入其消息。
    func load(_ session: ChatSession) {
        guard session.id != currentSession?.id else { return }
        currentSession = session
        messages = session.orderedMessages.map(\.asChatMessage)
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
            input = ""
            if case .failed = state { state = .idle }
            return
        }

        input = snapshot.input
        pendingRestoredSessionID = snapshot.currentSessionID
        currentSession = nil
        messages = []
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

    /// 发送当前输入。`serverContext` 是当前活动服务器的简述，进 system prompt。
    func send(serverContext: String) async {
        guard state != .streaming, state != .running else { return }
        let prompt = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        guard let provider = activeProvider else {
            state = .failed("尚未配置 AI provider")
            return
        }
        guard let key = keyOverride ?? keychain.load(for: provider.id) else {
            state = .failed("当前 provider 缺少 API Key")
            return
        }
        guard let baseURL = resolveBaseURL(for: provider) else {
            state = .failed("当前 provider 的 baseURL 非法")
            return
        }

        lastServerContext = serverContext
        input = ""
        let userMessage = ChatMessage(role: .user, text: prompt)
        messages.append(userMessage)

        // 惰性建会话并落库用户消息（无 context 时纯内存）。
        let session = ensureSession(firstPrompt: prompt)
        persist(userMessage, in: session)

        await streamAssistantTurn(provider: provider, key: key, baseURL: baseURL,
                                  serverContext: serverContext, session: session)
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
        let client = clientOverride ?? LLMClientFactory.make(for: provider)
        let system = Self.systemPrompt(serverContext: serverContext)
        do {
            for try await event in client.stream(messages: conversation,
                                                  system: system, config: config) {
                switch event {
                case .text(let delta):
                    messages[assistantIndex].text += delta
                case .toolCall(let call):
                    messages[assistantIndex].toolCalls.append(ToolCallState(from: call))
                }
            }
            let pending = messages[assistantIndex].toolCalls.contains { $0.status == .pending }
            state = pending ? .awaitingApproval : .idle
        } catch {
            let message = errorMessage(for: error, kind: provider.kind)
            messages[assistantIndex].text += "\n[错误：\(message)]"
            state = .failed(message)
        }
        // 流式结束后把助手最终文本与工具调用写回记录。
        finalize(assistantRecord, text: messages[assistantIndex].text,
                 toolCalls: messages[assistantIndex].toolCalls, in: session)
    }

    // MARK: - 工具调用：批准 / 跳过 / 执行 / 续轮

    /// 批准并执行某条工具调用；全部 resolved 后自动续轮。
    func approveAndRun(id: String) async {
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
        guard let provider = activeProvider,
              let key = keyOverride ?? keychain.load(for: provider.id),
              let baseURL = resolveBaseURL(for: provider) else { state = .idle; return }
        await streamAssistantTurn(provider: provider, key: key, baseURL: baseURL,
                                  serverContext: serverContext, session: currentSession)
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
        if !provider.baseURL.isEmpty, let url = URL(string: provider.baseURL) {
            return url
        }
        return URL(string: ProviderPreset.defaultBaseURL(for: provider.kind))
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
