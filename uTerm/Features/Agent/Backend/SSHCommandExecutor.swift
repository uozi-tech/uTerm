import Foundation

/// 真实命令执行器：把命令包成「总是 exit 0、附带真实退出码哨兵」的形式发给 SSH exec，
/// 这样非零退出也能拿到输出与退出码（Citadel `executeCommand` 默认非零会抛错）。
/// `exec` 闭包由调用方用工作区的 `ConnectedClient.exec` 提供。
nonisolated struct SSHCommandExecutor: CommandExecutor {
    static let sentinel = "__UTERM_EXIT__"
    let maxLines: Int
    let maxBytes: Int
    private let exec: @Sendable (String) async throws -> String

    init(maxLines: Int = 200, maxBytes: Int = 16_000,
         exec: @escaping @Sendable (String) async throws -> String) {
        self.maxLines = maxLines; self.maxBytes = maxBytes; self.exec = exec
    }

    func run(_ command: String) async throws -> CommandResult {
        // 合并 stderr，永远 exit 0，末行打印真实退出码哨兵。
        let wrapped = "{ \(command) ; } 2>&1; printf '\\n\(Self.sentinel):%d\\n' \"$?\""
        let raw = try await exec(wrapped)
        return Self.parse(raw, maxLines: maxLines, maxBytes: maxBytes)
    }

    nonisolated static func parse(_ raw: String, maxLines: Int, maxBytes: Int) -> CommandResult {
        var exitCode: Int?
        var body = raw
        if let range = raw.range(of: "\(sentinel):", options: .backwards) {
            let after = raw[range.upperBound...]
            exitCode = Int(after.prefix { $0.isNumber })
            body = String(raw[..<range.lowerBound])
        }
        body = body.trimmingCharacters(in: .newlines)

        var truncated = false
        var lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > maxLines { lines = Array(lines.prefix(maxLines)); truncated = true }
        var out = lines.joined(separator: "\n")
        if out.utf8.count > maxBytes { out = String(out.prefix(maxBytes)); truncated = true }
        if truncated { out += "\n… [输出已截断]" }
        return CommandResult(output: out, exitCode: exitCode)
    }
}
