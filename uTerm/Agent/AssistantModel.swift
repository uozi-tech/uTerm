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
        case failed(String)
    }

    private(set) var messages: [ChatMessage] = []
    var input: String = ""
    private(set) var state: State = .idle

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
        guard state != .streaming else { return }
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

        input = ""
        let userMessage = ChatMessage(role: .user, text: prompt)
        messages.append(userMessage)
        let conversation = messages

        // 惰性建会话并落库用户消息（无 context 时纯内存）。
        let session = ensureSession(firstPrompt: prompt)
        persist(userMessage, in: session)

        let assistantMessage = ChatMessage(role: .assistant, text: "")
        messages.append(assistantMessage)
        let assistantIndex = messages.count - 1
        let assistantRecord = persist(assistantMessage, in: session)
        state = .streaming

        let config = LLMRequestConfig(model: provider.model,
                                       baseURL: baseURL, apiKey: key)
        let client = clientOverride ?? LLMClientFactory.make(for: provider)
        let system = Self.systemPrompt(serverContext: serverContext)
        do {
            for try await delta in client.stream(messages: conversation,
                                                  system: system, config: config) {
                messages[assistantIndex].text += delta
            }
            state = .idle
        } catch {
            let message = errorMessage(for: error, kind: provider.kind)
            messages[assistantIndex].text += "\n[错误：\(message)]"
            state = .failed(message)
        }
        // 流式结束后把助手最终文本写回记录。
        finalize(assistantRecord, text: messages[assistantIndex].text, in: session)
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
                                       id: message.id, createdAt: Date())
        record.session = session
        ctx.insert(record)
        session.updatedAt = Date()
        try? ctx.save()
        return record
    }

    private func finalize(_ record: ChatMessageRecord?, text: String, in session: ChatSession?) {
        guard let ctx = modelContext, let record else { return }
        record.text = text
        session?.updatedAt = Date()
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
