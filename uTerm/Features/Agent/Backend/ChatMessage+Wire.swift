import AgentKit
import Foundation

// 会话消息 → 请求层消息（`AgentKit.LLMWireMessage`）。序列化、SSE 解析、传输都在 AgentKit，
// uTable 共用同一套；这里只做本应用消息模型的转换。

nonisolated extension ChatMessage {
    /// 把会话编排成请求消息。assistant 的工具调用展开为一条 assistant + 每个调用一条结果
    /// （本应用的结果内嵌在 `ToolCallState` 里，请求层的是独立消息）。
    ///
    /// - Parameter replayThinking: 开着思考时为 true —— 最后一条「开新一轮」的用户消息之后
    ///   （即本轮工具循环里）的 assistant 消息带上 thinking 块。更早的轮次不带：从历史前端
    ///   整段移除是 API 允许的形状，而且出站压缩会改写旧轮次，回传反而会被判签名不符。
    ///   循环中途并进来的用户消息（`continuesTurn`）不算新一轮。
    static func wireMessages(system: String = "", conversation: [ChatMessage],
                             replayThinking: Bool = false) -> [LLMWireMessage] {
        var out: [LLMWireMessage] = []
        if !system.isEmpty { out.append(.system(system)) }
        let turnStart = replayThinking
            ? (conversation.lastIndex(where: { $0.role == .user && !$0.continuesTurn }) ?? -1) + 1
            : conversation.count
        for (offset, message) in conversation.enumerated() {
            switch message.role {
            case .user:
                out.append(.user(message.text))
            case .assistant:
                out.append(.assistant(text: message.text,
                                      toolCalls: message.toolCalls.map(\.wireCall),
                                      thinking: offset >= turnStart ? message.thinking : []))
                for call in message.toolCalls {
                    out.append(.toolResult(toolCallID: call.id, content: call.wireResultContent, isError: false))
                }
            }
        }
        return out
    }
}

nonisolated extension ToolCallState {
    var wireCall: LLMToolCall {
        LLMToolCall(id: id, name: name, argumentsJSON: wireArgumentsJSON)
    }

    /// 回传给模型的参数。卡片只留了解析后的 `command` / `explanation`，这里按原形状拼回去。
    var wireArgumentsJSON: String {
        var object: [String: Any] = ["command": command]
        if let explanation { object["explanation"] = explanation }
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    /// 回传给模型的结果文本。
    var wireResultContent: String {
        switch status {
        case .skipped: return "(用户跳过了该命令)"
        default: return output ?? ""
        }
    }
}

nonisolated extension ToolSpec {
    var wireSchema: LLMToolSchema {
        let data = (try? JSONSerialization.data(withJSONObject: schemaObject(), options: [.sortedKeys])) ?? Data("{}".utf8)
        return LLMToolSchema(name: name, description: description,
                             parametersJSON: String(decoding: data, as: UTF8.self))
    }
}

nonisolated extension LLMRequestConfig {
    /// 这次请求发往哪里：Base URL 是根地址，路径在这里补。
    func wireEndpoint(for wireProtocol: AgentWireProtocol) -> LLMWireEndpoint {
        let path: String
        switch wireProtocol {
        case .anthropic: path = "v1/messages"
        case .openAICompatible: path = "v1/chat/completions"
        }
        return LLMWireEndpoint(url: baseURL.appendingPathComponent(path), apiKey: apiKey,
                               wireProtocol: wireProtocol)
    }
}
