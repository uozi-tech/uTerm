import Foundation
@testable import uTerm

/// 测试用命令执行器：按命令返回脚本化结果，或抛错。
final class MockCommandExecutor: CommandExecutor, @unchecked Sendable {
    var results: [String: CommandResult] = [:]
    var defaultResult = CommandResult(output: "ok", exitCode: 0)
    var error: Error?
    private(set) var ran: [String] = []

    func run(_ command: String) async throws -> CommandResult {
        ran.append(command)
        if let error { throw error }
        return results[command] ?? defaultResult
    }
}
