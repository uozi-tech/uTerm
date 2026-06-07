import Foundation

nonisolated struct CommandResult: Sendable, Equatable {
    let output: String
    let exitCode: Int?
}

/// 在已连接服务器上执行一条命令。真实实现走 SSH exec；测试用 mock。
protocol CommandExecutor: Sendable {
    func run(_ command: String) async throws -> CommandResult
}
