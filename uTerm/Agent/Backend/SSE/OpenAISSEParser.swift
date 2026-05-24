import Foundation

/// 解析 OpenAI Chat Completions API（以及 OpenAI-兼容端点）的 SSE 流。
/// 逐行喂入；`data:` 行若含 choices[0].delta.content 则产出文本增量，
/// `data: [DONE]` 与其余行返回 nil。纯逻辑、无网络，便于单测。
nonisolated struct OpenAISSEParser {
    mutating func parse(line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst("data:".count)
            .trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]" else { return nil }
        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let delta = first["delta"] as? [String: Any],
              let content = delta["content"] as? String
        else { return nil }
        return content
    }
}
