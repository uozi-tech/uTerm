import AgentKit
import Foundation

/// 解析 Anthropic Claude Messages SSE。逐行喂入，产出 `[LLMEvent]`。
/// 文本块 `text_delta` → `.text`；`tool_use` 块的 `input_json_delta` 按 index 累积，
/// `content_block_stop` 时 flush 成 `.toolCall`。
nonisolated struct AnthropicSSEParser {
    private struct Tool { var id = ""; var name = ""; var args = "" }
    private var tools: [Int: Tool] = [:]   // 仅 tool_use 块进表

    mutating func parse(line: String) -> [LLMEvent] {
        guard line.hasPrefix("data:") else { return [] }
        let jsonText = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        guard let data = jsonText.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String
        else { return [] }
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
        default:
            return []
        }
    }
}
