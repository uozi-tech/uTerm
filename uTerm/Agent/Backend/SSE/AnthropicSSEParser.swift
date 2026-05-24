import Foundation

/// 解析 Anthropic Claude Messages API 的 SSE 流。逐行喂入；`data:` 行里若是
/// `content_block_delta` 的 `text_delta` 则产出文本增量，其余行产出 nil。
/// 纯逻辑、无网络，便于单测。
nonisolated struct AnthropicSSEParser {
    /// 喂入一行。返回该行携带的助手文本增量；非文本增量行返回 nil。
    mutating func parse(line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let jsonText = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        guard let data = jsonText.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        guard obj["type"] as? String == "content_block_delta",
              let delta = obj["delta"] as? [String: Any],
              delta["type"] as? String == "text_delta",
              let text = delta["text"] as? String
        else { return nil }
        return text
    }
}
