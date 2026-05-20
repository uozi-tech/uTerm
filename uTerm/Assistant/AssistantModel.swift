import SwiftUI

/// AI 助手聊天的对话状态机。
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
    /// 是否已有可用 API Key；观察属性，保存后驱动 UI 从空状态切到聊天。
    private(set) var hasAPIKey: Bool
    /// 上一次保存 API Key 是否失败（钥匙串写入出错）。
    private(set) var keySaveFailed = false

    private let backend: AssistantBackend
    private let apiKeyStore: APIKeyStore
    /// 测试直接注入的 key；非 nil 时优先于 `apiKeyStore`。
    private var injectedKey: String?

    /// 生产构造。
    init(backend: AssistantBackend = ClaudeClient(),
         apiKeyStore: APIKeyStore = APIKeyStore()) {
        self.backend = backend
        self.apiKeyStore = apiKeyStore
        self.hasAPIKey = apiKeyStore.load() != nil
    }

    /// 测试构造：注入后端与一个固定 key。
    convenience init(backend: AssistantBackend, apiKey: String) {
        self.init(backend: backend, apiKeyStore: APIKeyStore())
        self.injectedKey = apiKey
        self.hasAPIKey = true
    }

    func saveAPIKey(_ key: String) {
        do {
            try apiKeyStore.save(key)
            hasAPIKey = true
            keySaveFailed = false
        } catch {
            keySaveFailed = true
        }
    }

    private func resolvedKey() -> String? {
        injectedKey ?? apiKeyStore.load()
    }

    /// 发送当前输入。`serverContext` 是当前活动服务器的简述，进 system prompt。
    func send(serverContext: String) async {
        guard state != .streaming else { return }
        let prompt = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        guard let key = resolvedKey() else {
            state = .failed("未设置 API Key")
            return
        }
        input = ""
        messages.append(ChatMessage(role: .user, text: prompt))
        let conversation = messages
        let assistant = ChatMessage(role: .assistant, text: "")
        messages.append(assistant)
        let assistantIndex = messages.count - 1
        state = .streaming

        let system = Self.systemPrompt(serverContext: serverContext)
        do {
            for try await delta in backend.stream(messages: conversation,
                                                  system: system, apiKey: key) {
                messages[assistantIndex].text += delta
            }
            state = .idle
        } catch {
            let message = Self.errorMessage(for: error)
            messages[assistantIndex].text += "\n[错误：\(message)]"
            state = .failed(message)
        }
    }

    /// 把后端错误转成对用户友好的说明。
    private static func errorMessage(for error: Error) -> String {
        guard let clientError = error as? ClaudeClientError else {
            return error.localizedDescription
        }
        switch clientError {
        case .httpError(let status, let body):
            if status == 401 {
                return "API Key 无效，请检查密钥。"
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
