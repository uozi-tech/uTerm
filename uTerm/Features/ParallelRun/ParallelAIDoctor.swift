import AgentKit
import Foundation

/// 并行执行「AI 介入」的模型后端，macOS 与 iOS 共用（这个文件两个 target 都编）。
/// 1. `turn(...)` —— 跑**一轮**带 `run_command` 工具的对话，返回文本 + 工具调用，
///    `ParallelAgentEngine` 据此驱动多步 Agent 循环。
/// 2. `synthesize(...)` —— 全部台落定后产出一句跨服务器中文汇总。
///
/// assistant 消息里带 output 的 toolCalls 会被两家 client 还原成 tool_use + tool_result，
/// 天然支持多轮工具对话。整体 `Sendable`，可在逐台并发任务里直接调用。
nonisolated struct ParallelAIDoctor: Sendable {
    let client: LLMClient
    let model: String
    let baseURL: URL
    let apiKey: String
    /// 模型请求失败后的退避时长；只有测试会换成 0。
    var retryDelay: @Sendable (Int) -> Duration = { ParallelAgentPolicy.retryDelay(afterAttempt: $0) }

    /// 模型一轮的产出：文本增量累加 + 本轮发起的工具调用（参数未解析）。
    nonisolated struct Turn: Sendable {
        let text: String
        let calls: [LLMToolCall]
    }

    /// 跑一轮对话。限流 / 过载 / 流中断等暂时性错误按 `ParallelAgentPolicy` 退避重试；
    /// 最终失败把错误带回去，调用方据此写明原因。
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
        // 带静默超时（与 `AssistantModel` 同一条路）：provider 只发 keep-alive 不出内容时这一轮
        // 永远不返回，泳道停在「诊断中」、整次运行不收尾也不记日志。
        let events = client.streamWithIdleTimeout(messages: messages, system: system, config: config)
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

    /// 全部台落定后产出一句跨服务器汇总。`lanes` = 逐台 (名称, 状态文案, 结论)。
    func synthesize(commandName: String, lanes: [(name: String, tone: String, summary: String)]) async -> String? {
        let system = "你是 uTerm 的运维助手。根据多台服务器的逐台执行结论，用 1-2 句中文白话给出整体汇总；"
            + "若有失败的服务器，点名并给一句复核建议（只讲成功 / 失败，不要单列「自愈」）。只输出汇总文本，不要 JSON、不要列表。"
        let body = lanes.map { "- \($0.name)：[\($0.tone)] \($0.summary)" }.joined(separator: "\n")
        let user = "命令「\(commandName)」在 \(lanes.count) 台服务器执行完成。逐台结论：\n\(body)"
        let t = try? await turn(messages: [ChatMessage(role: .user, text: user)], system: system, withTools: false).get()
        let text = t?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    // MARK: - 结论解析

    /// 从模型「不再调用工具」那轮的文本里抠出结论 JSON：`{"status":"ok|failed","summary":"…"}`。
    /// 容忍前后说明 / ``` 包裹。无 JSON 时返回 nil（由调用方按是否执行过命令推断、用原文兜底摘要）。
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

    // MARK: - 构造

    /// 从 AI provider 构造：没 provider / 没 key / 地址解析不出 / 没选模型 → nil（调用方退回模板叙述）。
    @MainActor
    static func make(provider: AIProvider?) -> ParallelAIDoctor? {
        guard let provider else { return nil }
        let key = AgentKeychain().load(for: provider.id) ?? ""
        guard !key.isEmpty, !provider.model.isEmpty else { return nil }
        guard case .success(let baseURL) = ProviderEndpointPolicy.resolve(
            configuredBaseURL: provider.baseURL, kind: provider.kind) else { return nil }
        return ParallelAIDoctor(client: LLMClientFactory.make(for: provider),
                                model: provider.model, baseURL: baseURL, apiKey: key)
    }

    /// 按 Agent 里选中的模型服务造（`AIProvider.active` 同一口径）；会读一次钥匙串，
    /// 只在命令开了 AI 介入时才调。
    @MainActor
    static func make(providers: [AIProvider], activeProviderID: UUID?) -> ParallelAIDoctor? {
        make(provider: AIProvider.active(in: providers, id: activeProviderID))
    }
}
