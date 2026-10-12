import AgentKit
import Foundation

/// 解析 Anthropic Claude Messages SSE。逐行喂入，产出 `[LLMEvent]`。
/// 文本块 `text_delta` → `.text`；`tool_use` 块的 `input_json_delta` 按 index 累积，
/// `content_block_stop` 时 flush 成 `.toolCall`。
///
/// 另记三样「流是怎么结束的」，供 client 在 EOF 时判定回复是否完整 —— 不记的话，
/// 流内报错 / 连接被掐 / 撞输出上限全都长得像「正常说完了」，用户只看到话说一半就停。
nonisolated struct AnthropicSSEParser {
    private struct Tool { var id = ""; var name = ""; var args = "" }
    private var tools: [Int: Tool] = [:]   // 仅 tool_use 块进表

    /// `message_delta.delta.stop_reason`（`end_turn` / `tool_use` / `max_tokens` …）。
    private(set) var stopReason: String?
    /// 收到过 `message_stop`。
    private(set) var sawMessageStop = false
    /// 流内 `error` 事件的可读文案（`类型：消息`）。
    private(set) var streamError: String?

    /// 解析出过至少一个事件（流确实开始了）。
    private(set) var sawEvent = false

    /// 流开始了却没有正常收尾。`stop_reason` 与 `message_stop` 任一即算收尾 —— 个别中转
    /// 不转发后者。一个事件都没有的空响应不算（那条路由上层报「模型未返回任何内容」）。
    var endedEarly: Bool { sawEvent && !sawMessageStop && stopReason == nil }

    mutating func parse(line: String) -> [LLMEvent] {
        guard line.hasPrefix("data:") else { return [] }
        let jsonText = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        guard let data = jsonText.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String
        else { return [] }
        sawEvent = true
        let index = obj["index"] as? Int ?? 0

        switch type {
        case "content_block_start":
            if let block = obj["content_block"] as? [String: Any],
               block["type"] as? String == "tool_use" {
                tools[index] = Tool(id: block["id"] as? String ?? "",
                                    name: block["name"] as? String ?? "", args: "")
            }
            return []
        case "content_block_delta":
            guard let delta = obj["delta"] as? [String: Any] else { return [] }
            if delta["type"] as? String == "text_delta", let t = delta["text"] as? String {
                return [.text(t)]
            }
            if delta["type"] as? String == "input_json_delta",
               let frag = delta["partial_json"] as? String {
                tools[index]?.args += frag
            }
            return []
        case "content_block_stop":
            guard let t = tools.removeValue(forKey: index) else { return [] }
            return [.toolCall(LLMToolCall(id: t.id, name: t.name, argumentsJSON: t.args))]
        case "message_delta":
            if let delta = obj["delta"] as? [String: Any],
               let reason = delta["stop_reason"] as? String {
                stopReason = reason
            }
            return []
        case "message_stop":
            sawMessageStop = true
            return []
        case "error":
            let error = obj["error"] as? [String: Any]
            let parts = [error?["type"] as? String, error?["message"] as? String]
                .compactMap { $0 }.filter { !$0.isEmpty }
            streamError = parts.isEmpty ? "未知错误" : parts.joined(separator: "：")
            return []
        default:
            return []
        }
    }
}
