import Foundation

/// 一个工具参数的最简 schema 描述（v1 仅 string 类型够用）。
nonisolated struct ToolParameter: Sendable, Equatable {
    let name: String
    let type: String        // "string"
    let description: String
    let required: Bool
}

/// 一个可被 LLM 调用的工具定义。serialize 成各家 provider 的请求格式。
nonisolated struct ToolSpec: Sendable, Equatable {
    let name: String
    let description: String
    let parameters: [ToolParameter]

    /// v1 唯一工具：在已连接服务器上执行 shell 命令。
    static let runCommand = ToolSpec(
        name: "run_command",
        description: "在用户当前已连接的服务器上执行一条 shell 命令并返回其标准输出/错误输出。"
            + "命令会先经用户确认再执行。用于排查与运维任务。"
            + "命令在非交互环境里执行（没有终端，也没有人能输入），不要执行需要交互的命令；连续 "
            + "\(Int(SupervisedExec.agentIdle.components.seconds)) 秒没有任何输出会被判定卡住并终止，"
            + "耗时又不出声的任务请放到后台或让它定期输出进度。",
        parameters: [
            ToolParameter(name: "command", type: "string",
                          description: "要执行的完整 shell 命令。", required: true),
            ToolParameter(name: "explanation", type: "string",
                          description: "一句话说明这条命令要做什么（展示给用户）。", required: false),
        ])

    private func schemaObject() -> [String: Any] {
        var props: [String: Any] = [:]
        for p in parameters {
            props[p.name] = ["type": p.type, "description": p.description]
        }
        return [
            "type": "object",
            "properties": props,
            "required": parameters.filter(\.required).map(\.name),
        ]
    }

    /// OpenAI Chat Completions `tools[]` 元素。
    func openAIJSON() -> [String: Any] {
        ["type": "function",
         "function": ["name": name, "description": description, "parameters": schemaObject()]]
    }

    /// Anthropic Messages `tools[]` 元素。
    func anthropicJSON() -> [String: Any] {
        ["name": name, "description": description, "input_schema": schemaObject()]
    }
}
