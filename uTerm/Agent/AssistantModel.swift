import SwiftUI

/// AI 助手聊天的对话状态机。多 provider：调用方把 providers 列表与
/// activeProviderID 灌进来（通常源自 SwiftData @Query 与 @AppStorage）。
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
        messages.append(ChatMessage(role: .user, text: prompt))
        let conversation = messages
        messages.append(ChatMessage(role: .assistant, text: ""))
        let assistantIndex = messages.count - 1
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
