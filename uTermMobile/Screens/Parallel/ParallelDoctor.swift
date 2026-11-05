import AgentKit
import Foundation

/// 并行执行 AI 视图的 LLM 后端（移植自 macOS `ParallelAIDoctor`，依赖均为 iOS 已编入的
/// `LLMClient` / `ToolSpec.runCommand` / `ChatMessage` / `LLMToolCall`）。
/// - `turn(...)`：跑一轮带 `run_command` 工具的对话，返回文本 + 工具调用 → 驱动多步自愈循环。
/// - `synthesize(...)`：全部台落定后产出一句跨服务器中文汇总。
nonisolated struct ParallelDoctor: Sendable {
    let client: LLMClient
    let model: String
    let baseURL: URL
    let apiKey: String
    /// 模型请求失败后的退避时长；只有测试会换成 0。
    var retryDelay: @Sendable (Int) -> Duration = { ParallelAgentPolicy.retryDelay(afterAttempt: $0) }

    nonisolated struct Turn: Sendable {
        let text: String
        let calls: [LLMToolCall]
    }

    /// 跑一轮对话；限流 / 过载 / 流中断等暂时性错误按 `ParallelAgentPolicy` 退避重试，
    /// 最终失败把原因带回去（改前一律 nil，泳道只能写「需人工介入」）。
    func turn(messages: [ChatMessage], system: String, withTools: Bool,
              onRetry: @Sendable (Int, Error) -> Void = { _, _ in }) async -> Result<Turn, Error> {
        await ParallelAgentPolicy.withRetry(delay: retryDelay, onRetry: onRetry) {
            try await self.streamTurn(messages: messages, system: system, withTools: withTools)
        }
    }

    private func streamTurn(messages: [ChatMessage], system: String, withTools: Bool) async throws -> Turn {
        var config = LLMRequestConfig(model: model, baseURL: baseURL, apiKey: apiKey)
        config.tools = withTools ? [.runCommand] : []
        var text = ""
        var calls: [LLMToolCall] = []
        // 套静默超时（与 `AssistantModel` 同一个）：provider 保持连接、只发 keep-alive 时
        // 这一轮永远不返回，泳道停在「诊断中」、整次运行不收尾也不记日志。
        let events = withIdleTimeout(
            client.stream(messages: messages, system: system, config: config),
            timeout: config.streamIdleTimeout)
        for try await event in events {
            switch event {
            case .text(let delta): text += delta
            case .toolCall(let call): calls.append(call)
            // 这里不开思考参数，不会有 thinking 块；即便有也无须回传。
            case .thinking: break
            }
        }
        return Turn(text: text, calls: calls)
    }

    func synthesize(commandName: String, lanes: [(name: String, tone: String, summary: String)]) async -> String? {
        let system = "你是 uTerm 的运维助手。根据多台服务器的逐台执行结论，用 1-2 句中文白话给出整体汇总；"
            + "若有失败的服务器，点名并给一句复核建议（只讲成功 / 失败，不要单列「自愈」）。只输出汇总文本，不要 JSON、不要列表。"
        let body = lanes.map { "- \($0.name)：[\($0.tone)] \($0.summary)" }.joined(separator: "\n")
        let user = "命令「\(commandName)」在 \(lanes.count) 台服务器执行完成。逐台结论：\n\(body)"
        let t = try? await turn(messages: [ChatMessage(role: .user, text: user)], system: system, withTools: false).get()
        let text = t?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    /// 从结论文本里抠出 `{"status":"ok|failed","summary":"…"}`。
    nonisolated static func parseConclusion(_ raw: String) -> (status: String, summary: String)? {
        guard let start = raw.firstIndex(of: "{"),
              let end = raw.lastIndex(of: "}"), start < end else { return nil }
        guard let data = String(raw[start...end]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let status = ((obj["status"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let summary = ((obj["summary"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !status.isEmpty || !summary.isEmpty else { return nil }
        return (status, summary)
    }

    /// 从当前 AIProvider 构造 doctor（无 provider / 无 key / 无模型 → nil，退回模板叙述）。
    @MainActor
    static func make(provider: AIProvider?) -> ParallelDoctor? {
        guard let provider else { return nil }
        let key = AgentKeychain().load(for: provider.id) ?? ""
        guard !key.isEmpty else { return nil }
        guard case .success(let baseURL) = ProviderEndpointPolicy.resolve(
            configuredBaseURL: provider.baseURL, kind: provider.kind) else { return nil }
        // 没选模型就没法发请求（不再有预置模型兜底）。
        guard !provider.model.isEmpty else { return nil }
        return ParallelDoctor(client: LLMClientFactory.make(for: provider),
                              model: provider.model, baseURL: baseURL, apiKey: key)
    }
}
