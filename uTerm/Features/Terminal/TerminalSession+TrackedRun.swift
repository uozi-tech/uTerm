import Foundation

/// 命令行 `terminal open -H <主机> -- <命令>` 在新窗口里跑的那条命令。
///
/// 命令照原样打进用户的登录 shell（用户看得见、能交互：输 sudo 密码、回答 `[Y/n]`），前后
/// 各包一个 `printf` 打私有 OSC 标记。标记不显示，被本会话的影子终端截住（引擎不认识的 OSC），记下起止位置与
/// 退出码 —— `terminal wait` 据此拿到这条命令的退出码和输出。
///
/// 打进去的一行长这样（`$?` 只认 POSIX 系 shell：bash / zsh / sh / ksh；fish、tcsh 拿不到）：
///
///     printf '\033]6973;S;1a2b3c4d\007'; (sudo ./bootstrap.zsh); printf '\033]6973;D;1a2b3c4d;%s\007' "$?"
///
/// 命令包在子 shell `( … )` 里：命令里的 `exit` 只退出子 shell —— 不包的话它会把用户这个
/// 窗口的登录 shell 一起退掉，会话断开，结果也就拿不到了。代价是命令里的 `cd` / `export`
/// 不会留在窗口里。
struct TerminalTrackedRun {
    /// 私有 OSC 号。终端引擎与常见 shell 集成都没用它。
    static let oscCode = 6973
    /// 命令长度上限：交互 shell 的行编辑器不卡行长，但打进去的东西用户要看得懂。
    static let maxCommandBytes = 4096

    enum Phase: Equatable {
        case pending
        case running
        case finished(Int)
    }

    let id: String
    let command: String
    let requestedAt: Date
    var phase: Phase = .pending
    var injected = false
    /// 起止标记到达时光标所在的位置（影子终端里的标记，跟着内容滚动）。
    var startMarker: ShadowTerminal.Marker?
    var endMarker: ShadowTerminal.Marker?
    var startedAt: Date?
    var finishedAt: Date?

    init(command: String, requestedAt: Date = Date()) {
        self.id = String(UUID().uuidString.prefix(8)).lowercased()
        self.command = command
        self.requestedAt = requestedAt
    }

    /// 打进 shell 的那一行（不含回车）。
    var inputLine: String {
        "printf '\\033]\(Self.oscCode);S;\(id)\\007'; (\(command)); "
            + "printf '\\033]\(Self.oscCode);D;\(id);%s\\007' \"$?\""
    }

    /// 只收单行命令：多行打进 shell 会变成续行提示，`$?` 也对不上。
    static func validate(_ command: String) -> String? {
        if command.contains("\n") || command.contains("\r") {
            return "命令不能有换行：多条命令用 && 或 ; 连起来，长脚本先 sftp put 到主机上再跑"
        }
        if command.utf8.count > maxCommandBytes {
            return "命令超过 \(maxCommandBytes) 字节：先把脚本 sftp put 到主机上再跑"
        }
        return nil
    }
}

extension TerminalSession {

    /// 影子终端报来一条引擎不认识的 OSC（`payload` 含开头的编号）。标记在输出解析到那里时发出，`cursor` 是那一刻的光标。
    func handleUnknownOSC(_ payload: Data, cursor: ShadowTerminal.Marker?) {
        let prefix = Data("\(TerminalTrackedRun.oscCode);".utf8)
        guard payload.starts(with: prefix) else { return }
        handleTrackedRunMarker(payload.dropFirst(prefix.count), cursor: cursor)
    }

    /// 登记一条要跑的命令。已连上就立刻打进去，否则等 `connect` 成功后再打。
    @discardableResult
    func startTrackedRun(_ command: String) -> TerminalTrackedRun {
        let run = TerminalTrackedRun(command: command)
        trackedRun = run
        injectPendingTrackedRun()
        return run
    }

    /// 连上之后把还没打进去的命令打进去。远端 shell 还在读 rc 文件也没关系：PTY 会先缓着。
    func injectPendingTrackedRun() {
        guard connectionState == .connected, var run = trackedRun, !run.injected else { return }
        run.injected = true
        trackedRun = run
        let line = run.inputLine
        Task { try? await injectInput(line, appendEnter: true) }
    }

    private func handleTrackedRunMarker(_ data: Data, cursor: ShadowTerminal.Marker?) {
        let text = String(decoding: data, as: UTF8.self)
        let parts = text.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, var run = trackedRun, parts[1] == run.id else { return }
        switch parts[0] {
        case "S" where run.phase == .pending:
            run.phase = .running
            run.startMarker = cursor
            run.startedAt = Date()
        case "D" where parts.count >= 3 && run.phase != .pending:
            run.phase = .finished(Int(parts[2]) ?? -1)
            run.endMarker = cursor
            run.finishedAt = Date()
        default:
            return
        }
        trackedRun = run
    }

    /// 当前这条命令的状态与输出。输出是起止标记之间的行（还没跑完就到光标为止），
    /// 软折行拼回一行；超过 `maxBytes` 只留最后那部分。
    func trackedRunSnapshot(terminalID: UUID, maxBytes: Int) -> ControlTerminalRun? {
        guard let run = trackedRun else { return nil }
        let alive: Bool
        switch connectionState {
        case .disconnected, .failed: alive = false
        case .idle, .connecting, .connected: alive = true
        }
        var state: String
        var exitCode: Int?
        switch run.phase {
        case .pending: state = alive ? "pending" : "disconnected"
        case .running: state = alive ? "running" : "disconnected"
        case .finished(let code):
            state = "finished"
            exitCode = code
        }

        var output: String?
        var truncated = false
        if let start = run.startMarker {
            // 起点所在的行已经被回滚上限裁掉时，从现存的第一行读起并标截断。
            let read = shadow.text(from: start, to: run.endMarker)
            truncated = read.truncated
            var lines = read.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
            var text = lines.joined(separator: "\n")
            if text.utf8.count > maxBytes {
                var bytes = Array(text.utf8.suffix(maxBytes))
                while let first = bytes.first, first & 0xC0 == 0x80 { bytes.removeFirst() }
                text = String(decoding: bytes, as: UTF8.self)
                truncated = true
            }
            output = text
        }

        return ControlTerminalRun(
            terminal: terminalID.uuidString,
            command: run.command,
            state: state,
            exitCode: exitCode,
            output: output,
            truncated: truncated,
            requestedAt: ControlProtocol.iso8601(run.requestedAt) ?? "",
            startedAt: ControlProtocol.iso8601(run.startedAt),
            finishedAt: ControlProtocol.iso8601(run.finishedAt)
        )
    }
}
