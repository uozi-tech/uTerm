import Foundation

/// 运行期/UI 状态：一次工具调用从「待确认」到「完成」的全过程。Codable 以便落库。
nonisolated struct ToolCallState: Equatable, Sendable, Codable, Identifiable {
    enum Status: String, Equatable, Sendable, Codable {
        case pending, running, done, skipped, failed
    }
    let id: String          // provider 工具 id
    let name: String        // run_command
    var command: String
    var explanation: String?
    var status: Status
    var output: String?
    var exitCode: Int?

    init(id: String, name: String, command: String, explanation: String? = nil,
         status: Status = .pending, output: String? = nil, exitCode: Int? = nil) {
        self.id = id; self.name = name; self.command = command
        self.explanation = explanation; self.status = status
        self.output = output; self.exitCode = exitCode
    }

    /// 从模型发来的工具调用构造 pending 状态；解析 `command` / `explanation`。
    init(from call: LLMToolCall) {
        var command = ""
        var explanation: String?
        if let data = call.argumentsJSON.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            command = obj["command"] as? String ?? ""
            explanation = obj["explanation"] as? String
        }
        self.init(id: call.id, name: call.name, command: command,
                  explanation: explanation, status: .pending)
    }
}
