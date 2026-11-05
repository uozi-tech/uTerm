import AgentKit
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
    var approvalReason: String?
    /// nil 且有 `approvalReason`：只读命令由规则放行，没经过 AI。
    var approvedByAI: Bool?

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

extension ToolCallState {
    /// 命令卡的三态：待确认 / 执行中 / 已结束（完成、失败、跳过都画成结束，展示输出）。
    /// 两端的命令卡组件（`UDToolCall` / `MToolCall`）各有自己的状态类型，都从这里映射。
    nonisolated enum Phase: Equatable, Sendable {
        case pending, running, done
    }

    nonisolated var phase: Phase {
        switch status {
        case .pending: return .pending
        case .running: return .running
        case .done, .failed, .skipped: return .done
        }
    }
}
