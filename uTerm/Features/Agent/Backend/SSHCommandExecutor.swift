import Foundation

/// 真实命令执行器：把命令包成「总是 exit 0、附带真实退出码哨兵」的形式发给 SSH exec，
/// 这样非零退出也能拿到输出与退出码（Citadel `executeCommand` 默认非零会抛错）。
/// `exec` 闭包由调用方用工作区的 `ConnectedClient.exec` 提供。
nonisolated struct SSHCommandExecutor: CommandExecutor {
    static let sentinel = "__UTERM_EXIT__"
    /// 输出被裁剪时追加在末尾的标记。别在别处重复这串字面量 —— 截断与否读
    /// `CommandResult.truncated`。
    static let truncationMarker = "… [输出已截断]"
    /// 流式执行的首行标记：`__UTERM_PID__:<会话 shell 的 pid>`。见 `wrapAnnouncingPID`。
    static let pidMarker = "__UTERM_PID__"
    let maxLines: Int
    let maxBytes: Int
    private let exec: @Sendable (String) async throws -> String
    /// 流式 exec：每到一块输出就回调一次，命令结束（EOF）才返回。nil = 底层只会整段
    /// 返回（测试替身、Agent），`runStreaming` 退回 `exec` 并在结束时一次性交付。
    private let execStream: (@Sendable (String, @escaping @Sendable (Data) -> Void) async throws -> Void)?

    init(maxLines: Int = 200, maxBytes: Int = 16_000,
         exec: @escaping @Sendable (String) async throws -> String,
         execStream: (@Sendable (String, @escaping @Sendable (Data) -> Void) async throws -> Void)? = nil) {
        self.maxLines = maxLines; self.maxBytes = maxBytes
        self.exec = exec; self.execStream = execStream
    }

    func run(_ command: String) async throws -> CommandResult {
        // 合并 stderr，永远 exit 0，末行打印真实退出码哨兵。
        //
        // **必须是子 shell `( … )`，不能是命令组 `{ …; }`**：命令组在当前 shell 里跑，
        // 顶层的 `exit 3` 会连整个 shell 一起退掉 —— 哨兵根本没机会打印，Citadel 对
        // 非零退出抛错，上层只看得到一个「连接失败」。子 shell 里 `exit N` 只退子
        // shell，`$?` 照样拿得到 N，哨兵照常带出来。
        //
        // 命令与 `)` 之间用**换行**分隔而不是 `;`：命令以 `# 注释` 结尾时，`;` 会被
        // 一起注释掉，换行才收得住。
        let wrapped = "( \(command)\n) 2>&1; printf '\\n\(Self.sentinel):%d\\n' \"$?\""
        let raw = try await exec(wrapped)
        return Self.parse(raw, maxLines: maxLines, maxBytes: maxBytes)
    }

    /// 与 `run` 同一套包装，外加**第一行**打印会话 shell 的 pid。
    ///
    /// sshd 给每个 exec 会话 `setsid()`，所以这个 pid 也是整个进程组的组号：看门狗
    /// 判定超时后另开一条 exec 跑 `kill -- -<pid>`，就能把命令连同它 fork 出来的子进程
    /// 一起收掉。光关 channel 做不到 —— 没有 PTY 的会话里，一个不往 stdout 写的进程
    /// （恰恰是会被判「静默」的那种）永远收不到 SIGPIPE。
    static func wrapAnnouncingPID(_ command: String) -> String {
        "printf '\(pidMarker):%d\\n' \"$$\"\n( \(command)\n) 2>&1; printf '\\n\(sentinel):%d\\n' \"$?\""
    }

    /// 流式跑一条已包装好的命令（通常是 `wrapAnnouncingPID` 的产物），原样把字节交给
    /// `onOutput`。解析与裁剪交给调用方（`SupervisedExec`）—— 它要边收边判静默。
    func runStreaming(_ wrapped: String, onOutput: @escaping @Sendable (Data) -> Void) async throws {
        if let execStream {
            try await execStream(wrapped, onOutput)
        } else {
            onOutput(Data(try await exec(wrapped).utf8))
        }
    }

    /// 不包装、整段返回地跑一条命令（杀进程组这类辅助命令用）。
    func runRaw(_ command: String) async throws -> String {
        try await exec(command)
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
        if truncated { out += "\n" + truncationMarker }
        return CommandResult(output: out, exitCode: exitCode, truncated: truncated)
    }
}
