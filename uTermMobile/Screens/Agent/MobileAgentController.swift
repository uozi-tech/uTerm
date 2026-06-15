import SwiftUI
import SwiftData
import Observation

/// iOS Agent 聊天控制器：复用 macOS 的 LLM 后端（`LLMClientFactory` / `LLMClient`），
/// 对选定的 `AIProvider` 做流式对话。v1 为纯对话（不挂 SSH 工具）。
@MainActor
@Observable
final class MobileAgentController {
    var messages: [ChatMessage] = []
    var streaming = false
    var errorText: String?

    /// 当前会话连接的目标主机描述（终端页 Agent 模式注入）。nil = 通用助手。
    var contextHint: String?

    @ObservationIgnored private var task: Task<Void, Never>?

    private var system: String {
        var s = "你是 uTerm 内置的运维助手，精通 Linux、SSH、Shell 与服务器排障。回答简洁、准确，必要时给出可直接执行的命令。"
        if let hint = contextHint, !hint.isEmpty {
            s += "\n当前终端会话连接的目标主机 —— \(hint)。用户的提问通常与这台主机相关，给命令时默认面向它。"
        }
        return s
    }

    func send(_ text: String, provider: AIProvider) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !streaming else { return }
        errorText = nil

        guard let key = AgentKeychain().load(for: provider.id), !key.isEmpty else {
            errorText = "尚未配置该 provider 的 API Key。"
            return
        }
        let baseURLString = provider.baseURL.isEmpty
            ? ProviderPreset.defaultBaseURL(for: provider.kind) : provider.baseURL
        guard let baseURL = URL(string: baseURLString) else {
            errorText = "Base URL 无效。"; return
        }
        let model = provider.model.isEmpty
            ? (ProviderPreset.models(for: provider.kind).first ?? "") : provider.model

        messages.append(ChatMessage(role: .user, text: trimmed))
        var assistant = ChatMessage(role: .assistant, text: "")
        messages.append(assistant)
        let assistantIndex = messages.count - 1

        let config = LLMRequestConfig(model: model, baseURL: baseURL, apiKey: key)
        let client = LLMClientFactory.make(for: provider)
        let history = messages.dropLast().map { $0 }  // 不含正在生成的空助手消息
        streaming = true

        task = Task { [weak self] in
            do {
                let stream = client.stream(messages: Array(history), system: self?.system ?? "", config: config)
                for try await event in stream {
                    if case .text(let delta) = event {
                        await MainActor.run {
                            guard let self, self.messages.indices.contains(assistantIndex) else { return }
                            assistant.text += delta
                            self.messages[assistantIndex] = assistant
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self?.errorText = error.localizedDescription
                    if let self, self.messages.indices.contains(assistantIndex),
                       self.messages[assistantIndex].text.isEmpty {
                        self.messages.remove(at: assistantIndex)
                    }
                }
            }
            await MainActor.run { self?.streaming = false }
        }
    }

    func stop() {
        task?.cancel()
        streaming = false
    }

    func clear() {
        stop()
        messages.removeAll()
        errorText = nil
    }
}
