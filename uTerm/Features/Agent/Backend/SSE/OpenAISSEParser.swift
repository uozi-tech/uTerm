import AgentKit
import Foundation

/// 解析 OpenAI Chat Completions（及兼容端点）SSE。逐行喂入，产出 `[LLMEvent]`。
/// 文本增量逐条 `.text`；工具调用按 `tool_calls[].index` 累积 id/name/arguments，
/// 在 `finish_reason == "tool_calls"` 或 `[DONE]` 时一次性 flush 成 `.toolCall`。
///
/// 兜底：有的兼容端点以 `finish_reason == "stop"`/`"length"` 收尾且不发 `[DONE]`，
/// 累积的工具调用就永远不会被 flush。client 在字节流 EOF 后须再调一次 `flush()`，
/// 借 `flushed` 标记保证幂等——已经 flush 过（经 `[DONE]` 或 `tool_calls`）则不再重复产出。
nonisolated struct OpenAISSEParser {
    private struct Accum { var id = ""; var name = ""; var args = "" }
    private var calls: [Int: Accum] = [:]
    private var order: [Int] = []
    /// 是否已 flush 过累积的工具调用（经 `[DONE]` / `finish_reason == "tool_calls"` /
    /// EOF 兜底任一）。置位后 `flush()` 不再产出，避免 EOF 兜底重复发同一调用。
    private var flushed = false

    /// 最后一次非空的 `finish_reason`（`stop` / `tool_calls` / `length` …）。
    private(set) var finishReason: String?
    /// 收到过 `[DONE]`。
    private(set) var sawDone = false
    /// 流内 `{"error":…}` 帧的可读文案。
    private(set) var streamError: String?

    /// 解析出过至少一帧 `choices`（流确实开始了）。
    private(set) var sawEvent = false

    /// 流开始了却没有正常收尾：`[DONE]` 与 `finish_reason` 任一即算收尾（有的兼容端点不发
    /// 前者）。一帧都没有的空响应不算（那条路由上层报「模型未返回任何内容」）。
    var endedEarly: Bool { sawEvent && !sawDone && finishReason == nil }

    mutating func parse(line: String) -> [LLMEvent] {
        guard line.hasPrefix("data:") else { return [] }
        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { sawDone = true; return flush() }
        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        if let error = obj["error"] {
            let message = (error as? [String: Any])?["message"] as? String ?? error as? String
            streamError = message.flatMap { $0.isEmpty ? nil : $0 } ?? "未知错误"
            return []
        }
        guard let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first
        else { return [] }
        sawEvent = true
        if let reason = first["finish_reason"] as? String { finishReason = reason }

        var out: [LLMEvent] = []
        if let delta = first["delta"] as? [String: Any] {
            if let content = delta["content"] as? String, !content.isEmpty {
                out.append(.text(content))
            }
            if let tcs = delta["tool_calls"] as? [[String: Any]] {
                for tc in tcs {
                    let idx = tc["index"] as? Int ?? 0
                    if calls[idx] == nil { calls[idx] = Accum(); order.append(idx) }
                    if let id = tc["id"] as? String { calls[idx]?.id = id }
                    if let fn = tc["function"] as? [String: Any] {
                        if let name = fn["name"] as? String { calls[idx]?.name = name }
                        if let args = fn["arguments"] as? String { calls[idx]?.args += args }
                    }
                }
            }
        }
        if first["finish_reason"] as? String == "tool_calls" {
            out.append(contentsOf: flush())
        }
        return out
    }

    /// 产出累积的工具调用并清空缓冲。幂等：已 flush 过（标记置位）直接返回空，
    /// 故 client 在 EOF 后无脑再调一次也不会重复发已发出的调用。
    /// 非 private，供 client 在字节流结束后兜底冲刷无 `[DONE]` 的工具调用。
    mutating func flush() -> [LLMEvent] {
        guard !flushed else { return [] }
        flushed = true
        let events = order.compactMap { idx -> LLMEvent? in
            guard let a = calls[idx] else { return nil }
            return .toolCall(LLMToolCall(id: a.id, name: a.name, argumentsJSON: a.args))
        }
        calls.removeAll(); order.removeAll()
        return events
    }
}
