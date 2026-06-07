import Foundation

/// 解析 OpenAI Chat Completions（及兼容端点）SSE。逐行喂入，产出 `[LLMEvent]`。
/// 文本增量逐条 `.text`；工具调用按 `tool_calls[].index` 累积 id/name/arguments，
/// 在 `finish_reason == "tool_calls"` 或 `[DONE]` 时一次性 flush 成 `.toolCall`。
nonisolated struct OpenAISSEParser {
    private struct Accum { var id = ""; var name = ""; var args = "" }
    private var calls: [Int: Accum] = [:]
    private var order: [Int] = []

    mutating func parse(line: String) -> [LLMEvent] {
        guard line.hasPrefix("data:") else { return [] }
        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return flush() }
        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first
        else { return [] }

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

    private mutating func flush() -> [LLMEvent] {
        let events = order.compactMap { idx -> LLMEvent? in
            guard let a = calls[idx] else { return nil }
            return .toolCall(LLMToolCall(id: a.id, name: a.name, argumentsJSON: a.args))
        }
        calls.removeAll(); order.removeAll()
        return events
    }
}
