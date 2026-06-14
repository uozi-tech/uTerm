import Foundation

/// 并行执行窗口 AI 视图的 LLM 后端。两个能力：
/// 1. `turn(...)` —— 跑**一轮**带工具的对话（`run_command`），返回模型这轮的文本 + 它发起的
///    工具调用。`ParallelRunModel` 据此驱动**多步自愈 Agent 循环**（提命令→真实执行→把输出回喂→
///    再决定下一条，如「更新后再重启、改配置后再校验」），直到模型不再调用工具并给出结论。
/// 2. `synthesize(...)` —— 全部台落定后产出一句跨服务器中文汇总。
///
/// 复用既有 `LLMClient` / `ToolSpec.runCommand` / `ChatMessage`（assistant 的 toolCalls 带 output
/// 会被两家 client 还原成 tool_use+tool_result，天然支持多轮工具对话）。整体 `Sendable`，可在
/// 模型的并发逐台任务里直接调用。
nonisolated struct ParallelAIDoctor: Sendable {
    let client: LLMClient
    let model: String
    let baseURL: URL
    let apiKey: String

    /// 模型一轮的产出：文本增量累加 + 本轮发起的工具调用（参数未解析）。
    nonisolated struct Turn: Sendable {
        let text: String
        let calls: [LLMToolCall]
    }

    /// 跑一轮对话。`withTools` 为真时挂上 `run_command` 工具。失败（网络/鉴权）返回 nil。
    func turn(messages: [ChatMessage], system: String, withTools: Bool) async -> Turn? {
        var config = LLMRequestConfig(model: model, baseURL: baseURL, apiKey: apiKey)
        config.tools = withTools ? [.runCommand] : []
        var text = ""
        var calls: [LLMToolCall] = []
        do {
            for try await event in client.stream(messages: messages, system: system, config: config) {
                switch event {
                case .text(let delta): text += delta
                case .toolCall(let call): calls.append(call)
                }
            }
        } catch {
            return nil
        }
        return Turn(text: text, calls: calls)
    }

    /// 全部台落定后产出一句跨服务器汇总。`lanes` = 逐台 (名称, 语气标签, 结论)。
    func synthesize(commandName: String, lanes: [(name: String, tone: String, summary: String)]) async -> String? {
        let system = "你是 uTerm 的运维助手。根据多台服务器的逐台执行结论，用 1-2 句中文白话给出整体汇总；"
            + "若有失败的服务器，点名并给一句复核建议（只讲成功 / 失败，不要单列「自愈」）。只输出汇总文本，不要 JSON、不要列表。"
        let body = lanes.map { "- \($0.name)：[\($0.tone)] \($0.summary)" }.joined(separator: "\n")
        let user = "命令「\(commandName)」在 \(lanes.count) 台服务器执行完成。逐台结论：\n\(body)"
        let t = await turn(messages: [ChatMessage(role: .user, text: user)], system: system, withTools: false)
        let text = t?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    // MARK: - 结论解析

    /// 从模型「不再调用工具」那轮的文本里抠出结论 JSON：`{"status":"ok|failed","summary":"…"}`。
    /// 容忍前后说明 / ``` 包裹。无 JSON 时返回 nil（由调用方按是否执行过命令推断语气、用原文兜底摘要）。
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
}
