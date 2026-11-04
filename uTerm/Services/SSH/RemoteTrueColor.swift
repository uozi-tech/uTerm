import Foundation

/// 让 SSH 那头的程序知道这个终端支持真彩。
///
/// Claude Code、Codex 靠 `COLORTERM` 判断真彩，没有就退到 256 色。常见的 sshd 默认只放行
/// `LANG` 和 `LC_*`，所以连接时发的 `COLORTERM` 多半到不了。`LC_TERMINAL` 通常能到，经用户
/// 确认后往远端 shell 配置加一行，用它把 `COLORTERM` 补上；别的终端连这台主机不受影响。
nonisolated enum RemoteTrueColor {

    /// 这台主机的现状。
    enum Status: Equatable, Sendable {
        /// 程序已经能看到 `COLORTERM`，或那一行已经写过，不用做什么。
        case active
        /// 服务器放行了 `LC_TERMINAL`，可以往这个文件加一行。
        case canEnable(rcFile: String)
        /// 服务器连 `LC_TERMINAL` 都不放行，这条路走不通，只能由管理员改 sshd 配置。
        case unsupported
    }

    /// 连接时发的环境变量取值，探测和交互 shell 共用。
    static let terminalName = "uTerm"
    static let colorTerm = "truecolor"

    /// 交互 shell 和探测命令发的环境变量。进程内的连接和 `uterm-ssh` 共用这一份。
    static let terminalEnvironment: [(name: String, value: String)] = [
        ("LANG", "en_US.UTF-8"),
        ("COLORTERM", colorTerm),
        ("LC_TERMINAL", terminalName),
    ]

    /// 重复启用时靠它认出已经加过。
    private static let marker = "# uTerm truecolor"

    /// 写进 shell 配置的那一行，确认框原样展示给用户。
    /// 用 `if` 而不是 `&&`：条件不成立时 `&&` 的退出码是 1，放在文件末尾会让第一个提示符显示「上一条失败」。
    static func rcLine(forFile file: String) -> String {
        file.hasSuffix(".fish")
            ? "if test \"$LC_TERMINAL\" = \(terminalName); set -gx COLORTERM \(colorTerm); end \(marker)"
            : "if [ \"$LC_TERMINAL\" = \(terminalName) ]; then export COLORTERM=\(colorTerm); fi \(marker)"
    }

    /// 选 shell 登录时一定会读的文件，子 shell 经环境变量继承。
    ///
    /// - zsh：`.zshenv` 所有 zsh 都读。
    /// - bash：登录 shell 只读三者中第一个存在的，加到别的文件不生效；都没有才新建。
    /// - 脚本里不能出现单引号：外层用单引号包给 `sh -c`，用户的登录 shell 可能是 fish，
    ///   它对 `'\''` 的解析和 POSIX 不同。
    private static let chooseRCFile = """
    case "${SHELL##*/}" in
      zsh) f="${ZDOTDIR:-$HOME}/.zshenv";;
      fish) f="$HOME/.config/fish/conf.d/uterm.fish";;
      bash) f=""; for c in .bash_profile .bash_login .profile; do if [ -e "$HOME/$c" ]; then f="$HOME/$c"; break; fi; done; f="${f:-$HOME/.profile}";;
      *) f="$HOME/.profile";;
    esac
    """

    /// 输出四行：`COLORTERM`、`LC_TERMINAL`、要改的文件、那一行是否已写过。
    ///
    /// 第四行不能省：探测是 `bash -c`，不读 `.profile`，写过之后这里依然看不到 `COLORTERM`，
    /// 只看环境变量的话提示会一直弹。
    static let probeCommand = """
    sh -c '\(chooseRCFile)
    if grep -qF "\(marker)" "$f" 2>/dev/null; then written=yes; else written=no; fi
    printf "%s\\n%s\\n%s\\n%s\\n" "$COLORTERM" "$LC_TERMINAL" "$f" "$written"'
    """

    /// 幂等地加上那一行，输出改的文件路径。
    static var enableCommand: String {
        func quoted(_ line: String) -> String {
            line.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "$", with: "\\$")
        }
        return """
        sh -c '\(chooseRCFile)
        case "$f" in
          *.fish) line="\(quoted(rcLine(forFile: ".fish")))";;
          *) line="\(quoted(rcLine(forFile: "")))";;
        esac
        mkdir -p "${f%/*}" || exit 1
        if ! grep -qF "\(marker)" "$f" 2>/dev/null; then printf "\\n%s\\n" "$line" >> "$f" || exit 1; fi
        printf "%s\\n" "$f"'
        """
    }

    static func parseProbe(_ output: String) -> Status {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 4 else { return .unsupported }
        if lines[0] == "truecolor" || lines[0] == "24bit" || lines[3] == "yes" { return .active }
        guard lines[1] == terminalName, !lines[2].isEmpty else { return .unsupported }
        return .canEnable(rcFile: lines[2])
    }

    /// 启用命令的输出：最后一行是改过的文件。末尾必须确实是路径，rc 里打印的杂讯可能排在前面。
    static func parseEnabledFile(_ output: String) -> String? {
        output.split(separator: "\n").last.map(String.init).flatMap { $0.hasPrefix("/") ? $0 : nil }
    }
}

/// 能查询、启用远端真彩的后端（目前只有 SSH）。
protocol TerminalTrueColorConfiguring: TerminalBackend {
    /// 提示「不再询问」时按这个键记住主机。
    nonisolated var trueColorHostKey: String { get }
    func trueColorStatus() async throws -> RemoteTrueColor.Status
    /// 写入远端 shell 配置，返回改的文件。
    func enableTrueColor() async throws -> String
}

nonisolated enum RemoteTrueColorError: LocalizedError {
    case notConnected
    case timedOut
    case unexpectedOutput

    var errorDescription: String? {
        switch self {
        case .notConnected: "终端还没连上"
        case .timedOut: "服务器没有响应"
        case .unexpectedOutput: "服务器没有确认写入，请检查登录 shell 和主目录权限"
        }
    }
}
