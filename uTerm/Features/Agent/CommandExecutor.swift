import Foundation

nonisolated struct CommandResult: Sendable, Equatable {
    let output: String
    let exitCode: Int?
    /// 输出被 `maxLines` / `maxBytes` 削过。由执行器直接带出 —— 调用方不必再去嗅探
    /// 输出末尾的截断标记（那种字面量比对一改文案就静默失效）。
    let truncated: Bool

    init(output: String, exitCode: Int?, truncated: Bool = false) {
        self.output = output
        self.exitCode = exitCode
        self.truncated = truncated
    }
}

/// 在已连接服务器上执行一条命令。真实实现走 SSH exec；测试用 mock。
nonisolated protocol CommandExecutor: Sendable {
    func run(_ command: String) async throws -> CommandResult
}
