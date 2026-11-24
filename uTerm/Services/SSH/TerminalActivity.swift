import Foundation

/// 终端的前台此刻在干什么。关标签前据此决定要不要二次确认。
nonisolated enum TerminalActivity: Equatable, Sendable {
    /// 前台是 shell 自己，停在提示符上。
    case idle
    /// 前台有程序在跑。关联值是程序名，读不到时为 nil。
    case running(String?)
    /// 判断不了（服务器没有可用的 `ps`、不让开 exec 通道、超时）。
    case unknown

    /// 探测结果判断不了时，用终端自己的状态兜底：备用屏只有全屏程序才会开。
    func resolved(alternateScreen: Bool) -> TerminalActivity {
        self == .unknown && alternateScreen ? .running(nil) : self
    }

    /// 先到先得：`probe` 没在 `timeout` 内回来就算判断不了。不等它响应取消：用户正等着关标签，
    /// 卡住的通道（半死的连接上开通道）收尾也要时间。
    static func probed(
        timeout: Duration,
        probe: @escaping @Sendable () async -> TerminalActivity
    ) async -> TerminalActivity {
        let (results, continuation) = AsyncStream.makeStream(of: TerminalActivity.self)
        let probing = Task { continuation.yield(await probe()) }
        let timer = Task {
            try? await Task.sleep(for: timeout)
            continuation.yield(.unknown)
        }
        defer {
            probing.cancel()
            timer.cancel()
            continuation.finish()
        }
        for await result in results { return result }
        return .unknown
    }

    /// 二次确认的文案。nil = 不用确认，直接关。
    /// `tabName` 是标签上显示的名字：同时开着好几个标签时，用户得知道要关的是哪一个。读不到时为 nil。
    func closePrompt(tabName: String? = nil) -> TerminalClosePrompt? {
        let tab = tabName?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty.map(TerminalTitle.clippedForTab)
        switch self {
        case .idle:
            return nil
        case .running(let name?):
            return TerminalClosePrompt(title: String(localized: "「\(name)」还在运行"),
                                       message: Self.interruptMessage(tab: tab))
        case .running(nil):
            return TerminalClosePrompt(title: String(localized: "这个标签页里还有程序在运行"),
                                       message: Self.interruptMessage(tab: tab))
        case .unknown:
            let message = tab.map {
                String(localized: "无法确认它现在的状态。关闭标签页「\($0)」会断开这个终端，里面的程序可能被中断。")
            } ?? String(localized: "无法确认它现在的状态。关闭标签页会断开这个终端，里面的程序可能被中断。")
            return TerminalClosePrompt(title: String(localized: "这个标签页里可能还有程序在运行"), message: message)
        }
    }

    private static func interruptMessage(tab: String?) -> String {
        tab.map { String(localized: "关闭标签页「\($0)」可能会中断它。") }
            ?? String(localized: "关闭这个标签页可能会中断它。")
    }
}

private extension String {
    nonisolated var nilIfEmpty: String? { isEmpty ? nil : self }
}

nonisolated struct TerminalClosePrompt: Equatable, Sendable {
    let title: String
    let message: String

    /// 关整个窗口时的确认。nil = 所有标签都没有程序在跑，不用问。
    static func forWindow(_ activities: [TerminalActivity]) -> TerminalClosePrompt? {
        var names: [String] = []
        var running = 0
        var unknown = 0
        for activity in activities {
            switch activity {
            case .idle:
                break
            case .running(let name):
                running += 1
                if let name, !names.contains(name) { names.append(name) }
            case .unknown:
                unknown += 1
            }
        }
        guard running + unknown > 0 else { return nil }
        guard running > 0 else {
            return TerminalClosePrompt(title: String(localized: "这个窗口里可能还有程序在运行"),
                                       message: String(localized: "有 \(unknown) 个标签页无法确认状态。关闭窗口会断开它们，里面的程序可能被中断。"))
        }
        let title = running == 1 && names.count == 1
            ? String(localized: "「\(names[0])」还在运行")
            : String(localized: "有 \(running) 个标签页还有程序在运行")
        let message: String
        if running > 1 && !names.isEmpty {
            // running > 1 时代词总是「它们」。
            let listed = names.joined(separator: String(localized: "、", comment: "列举进程名的分隔符"))
            message = String(localized: "\(listed)。关闭这个窗口可能会中断它们。")
        } else if running + unknown > 1 {
            message = String(localized: "关闭这个窗口可能会中断它们。")
        } else {
            message = String(localized: "关闭这个窗口可能会中断它。")
        }
        return TerminalClosePrompt(title: title, message: message)
    }
}

/// 从远端 `ps` 的输出判断某个 shell 的前台进程组。
///
/// 只看前台，不看后台：powerlevel10k 的 gitstatusd 这类提示符助手常驻在同一个终端上，
/// 把后台进程算进来的话，开了它们的标签每次关闭都要确认。
nonisolated struct RemoteProcessTable {
    struct Process: Equatable {
        let pid: Int32
        let ppid: Int32
        let pgid: Int32
        /// 这个进程的控制终端上的前台进程组。没有控制终端时 ≤ 0。
        let tpgid: Int32
        /// 控制终端（`pts/3`、`ttys001`），没有时为 nil。
        let tty: String?
        let name: String
    }

    /// 包一层 `sh -c`：exec 走的是用户的登录 shell，可能是 fish / csh。
    /// `-o` 分开写：BSD 和 POSIX 的 `pid=,ppid=` 会把逗号后面全当成表头。
    static let command = #"sh -c 'echo "uterm-ps-begin $$"; "#
        + #"ps -A -o pid= -o ppid= -o pgid= -o tpgid= -o tty= -o comm=; echo uterm-ps-end'"#

    private static let knownShells: Set<String> = [
        "sh", "bash", "zsh", "fish", "dash", "ash", "ksh", "mksh", "csh", "tcsh", "nu", "xonsh", "elvish", "pwsh",
    ]

    let probePID: Int32
    let processes: [Int32: Process]

    /// 解析 `command` 的输出。没看到完整的起止标记、或一行进程都没有时返回 nil。
    /// 起始标记前可能有 rc 文件打印的内容，一并跳过。
    init?(output: String) {
        let lines = output.split(whereSeparator: \.isNewline)
        guard let begin = lines.firstIndex(where: { $0.hasPrefix("uterm-ps-begin ") }),
              let end = lines[begin...].firstIndex(of: "uterm-ps-end"),
              let probePID = Int32(lines[begin].dropFirst("uterm-ps-begin ".count)) else { return nil }
        let rows = lines[(begin + 1)..<end].compactMap(Self.parse)
        guard !rows.isEmpty else { return nil }
        self.probePID = probePID
        processes = Dictionary(rows.map { ($0.pid, $0) }, uniquingKeysWith: { _, last in last })
    }

    private static func parse(_ line: Substring) -> Process? {
        let fields = line.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 6,
              let pid = Int32(fields[0]), let ppid = Int32(fields[1]),
              let pgid = Int32(fields[2]), let tpgid = Int32(fields[3]) else { return nil }
        let tty = fields[4]
        return Process(pid: pid,
                       ppid: ppid,
                       pgid: pgid,
                       tpgid: tpgid,
                       tty: tty.allSatisfy { $0 == "?" || $0 == "-" } ? nil : String(tty),
                       name: displayName(fields[5...].joined(separator: " ")))
    }

    /// macOS 的 `comm` 是完整路径，登录 shell 还带前导 `-`。
    private static func displayName(_ comm: String) -> String {
        let base = comm.split(separator: "/").last.map(String.init) ?? comm
        return base.hasPrefix("-") ? String(base.dropFirst()) : base
    }

    /// 这条 SSH 连接上开着终端的所有 shell。OpenSSH 每条连接一个会话进程，通道的子进程都挂在它下面，
    /// exec 通道也一样：从探测进程往上找到它，它名下带终端的子进程就是这条连接的 shell。
    var shells: [Process] {
        var current = processes[probePID]
        var remainingHops = 16
        while let process = current, remainingHops > 0, !Self.isSSHServer(process.name) {
            current = processes[process.ppid]
            remainingHops -= 1
        }
        guard let server = current, Self.isSSHServer(server.name) else { return [] }
        return processes.values
            .filter { $0.ppid == server.pid && $0.tty != nil }
            .sorted { $0.pid < $1.pid }
    }

    func activity(of shell: Process) -> TerminalActivity {
        guard shell.tpgid > 0 else { return .unknown }
        if shell.tpgid == shell.pgid {
            // 前台就是会话首进程。它不是 shell（rc 里 `exec tmux`）时，本身就是在跑的程序。
            return Self.knownShells.contains(shell.name) ? .idle : .running(shell.name)
        }
        let leader = processes[shell.tpgid] ?? processes.values.first { $0.pgid == shell.tpgid }
        return .running(leader?.name)
    }

    /// 终端前台那个进程：前台进程组的组长；前台就是 shell 自己（或认不出组长）时是 shell。
    func foregroundPID(of shell: Process) -> Int32 {
        guard shell.tpgid > 0, shell.tpgid != shell.pgid else { return shell.pid }
        if let leader = processes[shell.tpgid] { return leader.pid }
        return processes.values.filter { $0.pgid == shell.tpgid }.map(\.pid).min() ?? shell.pid
    }

    private static func isSSHServer(_ name: String) -> Bool {
        name.hasPrefix("sshd") || name == "dropbear"
    }
}

/// 同一条 SSH 连接上有多个 shell 时，认出哪个终端是自己的。
///
/// SSH 协议不告诉客户端通道对应的 pty，shell 里又不能打字进去。办法是往每个候选 pty 写一条
/// 不显示的私有 OSC，内容就是 pty 名：它顺着 pty 流回对应的通道，谁收到谁就是谁。
/// 写之前程序可能正写到一半（一条转义序列被隔开），所以只在确实分不清时才做，结果也缓存下来，
/// 每个标签最多一次。
nonisolated struct TTYMarkerScanner {
    /// 私有 OSC 号，紧跟 `TerminalTrackedRun.oscCode`。终端引擎对不认识的 OSC 不做任何显示。
    static let oscCode = 6974

    private static let prefix = Data("\u{1b}]\(oscCode);".utf8)
    private static let terminator: UInt8 = 0x07
    private static let maxNameBytes = 64

    private var pending = Data()

    /// 给每个 pty 写标记的命令。pty 名来自服务器，不合规矩的直接略过，不拼进命令。
    static func command(forTTYs ttys: [String]) -> String? {
        let safe = ttys.filter { tty in
            !tty.isEmpty && tty.utf8.count <= maxNameBytes
                && tty.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "/_-".contains($0)) }
                && !tty.contains("..")
        }
        guard !safe.isEmpty else { return nil }
        let list = safe.joined(separator: " ")
        return "sh -c 'for t in \(list); do printf \"\\033]\(oscCode);%s\\007\" \"$t\" > \"/dev/$t\"; done; true'"
    }

    /// 喂一段输出。标记可能被拆在两段里，所以留一点尾巴。
    mutating func feed(_ chunk: Data) -> String? {
        pending.append(chunk)
        defer { trimPending() }
        guard let start = pending.range(of: Self.prefix) else { return nil }
        let nameStart = start.upperBound
        guard let end = pending[nameStart...].firstIndex(of: Self.terminator) else { return nil }
        let name = String(decoding: pending[nameStart..<end], as: UTF8.self)
        pending.removeAll()
        return name.isEmpty ? nil : name
    }

    private mutating func trimPending() {
        let keep = Self.prefix.count + Self.maxNameBytes + 1
        if pending.count > keep { pending = Data(pending.suffix(keep)) }
    }
}
