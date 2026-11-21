import Foundation

/// 体验主机的模拟 shell：在 `DemoFileSystem` 上跑一小套常用命令（ls / cd / cat / echo > / mkdir / grep / find …）。
/// iOS 上起不了真进程，这里是解释执行；不认识的命令按 bash 的样子回 `command not found`。
///
/// 两种用法：
/// - 交互（终端标签）：`start()` 拿开场白与提示符，之后把键盘字节交给 `receive(_:)`，它负责回显、行编辑、
///   历史、补全，回车时执行。提示符带 OSC 7（当前目录）与 OSC 133（命令标记），影子终端照常认。
/// - 一次性（文件页的 `exec`，搜索 / 递归改权限）：`run(_:)`，输出不着色、换行是 `\n`。
///
/// 不是线程安全的：一个实例只归一个 actor 用（终端后端、文件页 provider 各持一个，共用同一份文件系统）。
nonisolated final class DemoShell {
    let fs: DemoFileSystem
    private(set) var cwd: String
    private(set) var history: [String] = []
    private var env: [String: String]
    private var lastStatus: Int32 = 0
    private let startedAt: Date
    private let now: () -> Date

    // 行编辑状态
    private var line: [Character] = []
    private var cursor = 0
    private var historyIndex: Int?
    private var savedLine: [Character] = []
    private var pendingEscape: String?
    private var lastWasCR = false

    init(fs: DemoFileSystem, now: @escaping () -> Date = Date.init) {
        self.fs = fs
        self.now = now
        startedAt = now()
        cwd = fs.isDirectory(DemoFileSystem.home) ? DemoFileSystem.home : "/"
        env = [
            "HOME": DemoFileSystem.home, "USER": DemoFileSystem.user, "LOGNAME": DemoFileSystem.user,
            "SHELL": "/bin/bash", "TERM": "xterm-256color", "LANG": "en_US.UTF-8",
            "PATH": "/usr/local/bin:/usr/bin:/bin", "HOSTNAME": DemoFileSystem.hostname,
        ]
        env["PWD"] = cwd
    }

    // MARK: - 交互

    /// 交互式会话的开头：开场白 + 第一个提示符。
    func start() -> String {
        let banner = String(localized: "这是 uTerm 的体验主机：一台模拟的 Linux，不联网，文件只在这台设备上。输入 help 查看能用的命令。")
        return "\u{1b}[1m\(banner)\u{1b}[0m\r\n\r\n" + promptSequence()
    }

    /// 处理一段键盘输入，返回要写到终端的字节。`exited` 为 true 表示用户 `exit` 了，会话该结束。
    func receive(_ text: String) -> (output: String, exited: Bool) {
        var out = ""
        for char in text {
            if var esc = pendingEscape {
                esc.append(char)
                if let done = finishEscape(esc) {
                    pendingEscape = nil
                    out += done
                } else {
                    pendingEscape = esc
                }
                continue
            }
            // 回车有的终端发 `\r`，有的发 `\r\n`（Swift 里是一个字符），分两次到达时 `\n` 别再算一次回车。
            let skipLF = char == "\n" && lastWasCR
            lastWasCR = char == "\r"
            if skipLF { continue }
            switch char {
            case "\u{1b}":
                pendingEscape = "\u{1b}"
            case "\r\n", "\r", "\n":
                let (echo, exited) = submit()
                out += echo
                if exited { return (out, true) }
            case "\u{7f}", "\u{8}":
                out += backspace()
            case "\u{3}":                       // Ctrl-C
                line = []; cursor = 0; historyIndex = nil
                lastStatus = 130
                out += "^C\r\n" + promptSequence()
            case "\u{4}":                       // Ctrl-D：空行时退出
                if line.isEmpty { return (out + "logout\r\n", true) }
                if cursor < line.count { line.remove(at: cursor); out += redraw() }
            case "\u{c}":                       // Ctrl-L
                out += "\u{1b}[H\u{1b}[2J" + promptSequence() + String(line) + cursorTail()
            case "\u{1}": cursor = 0; out += redraw()                       // Ctrl-A
            case "\u{5}": cursor = line.count; out += redraw()              // Ctrl-E
            case "\u{15}": line.removeFirst(cursor); cursor = 0; out += redraw()   // Ctrl-U
            case "\u{b}": line.removeLast(line.count - cursor); out += redraw()   // Ctrl-K
            case "\u{17}": out += deleteWord()                              // Ctrl-W
            case "\t": out += complete()
            default:
                guard !(char.unicodeScalars.first.map { $0.value < 0x20 } ?? true) else { continue }
                line.insert(char, at: cursor)
                cursor += 1
                out += cursor == line.count ? String(char) : redraw()
            }
        }
        return (out, false)
    }

    /// 一次性执行（文件页的 exec）：输出不着色、`\n` 换行，stderr 并进来（同 SSH exec 的合并输出）。
    func run(_ commandLine: String) -> String {
        execute(commandLine, tty: false).out
    }

    // MARK: - 行编辑

    private static let promptHost = "\(DemoFileSystem.user)@\(DemoFileSystem.hostname)"

    private func promptText() -> String {
        "\u{1b}[1;32m\(Self.promptHost)\u{1b}[0m:\u{1b}[1;34m\(DemoFileSystem.display(cwd))\u{1b}[0m$ "
    }

    /// OSC 7 报当前目录，OSC 133 标出提示符的起止（影子终端据此做命令标记）。
    private func promptSequence() -> String {
        let url = "file://\(DemoFileSystem.hostname)\(cwd.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? cwd)"
        return "\u{1b}]7;\(url)\u{7}\u{1b}]133;A\u{7}" + promptText() + "\u{1b}]133;B\u{7}"
    }

    private func cursorTail() -> String {
        let back = Self.width(line[cursor...])
        return back > 0 ? "\u{1b}[\(back)D" : ""
    }

    private func redraw() -> String {
        "\r" + promptText() + String(line) + "\u{1b}[K" + cursorTail()
    }

    private func backspace() -> String {
        guard cursor > 0 else { return "\u{7}" }
        let removed = line.remove(at: cursor - 1)
        cursor -= 1
        if cursor == line.count {
            return String(repeating: "\u{8}", count: Self.width(removed)) + "\u{1b}[K"
        }
        return redraw()
    }

    private func deleteWord() -> String {
        var start = cursor
        while start > 0, line[start - 1] == " " { start -= 1 }
        while start > 0, line[start - 1] != " " { start -= 1 }
        guard start < cursor else { return "" }
        line.removeSubrange(start..<cursor)
        cursor = start
        return redraw()
    }

    /// ESC 之后攒到一个完整序列就处理；还不完整返回 nil。认得 CSI（`ESC [ … final`）与 SS3（`ESC O x`）。
    private func finishEscape(_ esc: String) -> String? {
        let body = esc.dropFirst()
        guard let lead = body.first else { return nil }
        if lead == "O" {
            guard body.count >= 2 else { return nil }
            return handleKey(String(body.dropFirst(1)))
        }
        guard lead == "[" else { return "" }        // Alt+键之类：吞掉
        guard let last = body.last, body.count >= 2,
              let ascii = last.asciiValue, (0x40...0x7e).contains(ascii) else {
            return body.count > 16 ? "" : nil
        }
        return handleKey(String(body.dropFirst(1)))
    }

    private func handleKey(_ code: String) -> String {
        switch code {
        case "A": return historyStep(-1)
        case "B": return historyStep(1)
        case "C":
            guard cursor < line.count else { return "" }
            let w = Self.width(line[cursor])
            cursor += 1
            return "\u{1b}[\(w)C"
        case "D":
            guard cursor > 0 else { return "" }
            cursor -= 1
            return "\u{1b}[\(Self.width(line[cursor]))D"
        case "H", "1~", "7~": cursor = 0; return redraw()
        case "F", "4~", "8~": cursor = line.count; return redraw()
        case "3~":
            guard cursor < line.count else { return "" }
            line.remove(at: cursor)
            return redraw()
        default: return ""
        }
    }

    private func historyStep(_ delta: Int) -> String {
        guard !history.isEmpty else { return "" }
        if historyIndex == nil {
            guard delta < 0 else { return "" }
            savedLine = line
            historyIndex = history.count
        }
        let next = historyIndex! + delta
        if next >= history.count {
            historyIndex = nil
            line = savedLine
        } else {
            guard next >= 0 else { return "" }
            historyIndex = next
            line = Array(history[next])
        }
        cursor = line.count
        return redraw()
    }

    private func submit() -> (String, Bool) {
        let command = String(line)
        line = []; cursor = 0; historyIndex = nil
        var out = "\r\n"
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return (out + promptSequence(), false) }
        if history.last != trimmed { history.append(trimmed) }
        out += "\u{1b}]133;C\u{7}"
        let result = execute(command, tty: true)
        if result.clear { out += "\u{1b}[H\u{1b}[2J" }
        out += Self.crlf(result.out + result.err)
        if result.exit { return (out + "logout\r\n", true) }
        out += "\u{1b}]133;D;\(lastStatus)\u{7}"
        return (out + promptSequence(), false)
    }

    // MARK: - 补全

    private func complete() -> String {
        let prefixText = String(line[..<cursor])
        let tokenStart = prefixText.lastIndex(of: " ").map { prefixText.index(after: $0) } ?? prefixText.startIndex
        let word = String(prefixText[tokenStart...])
        let isCommand = prefixText[..<tokenStart].trimmingCharacters(in: .whitespaces).isEmpty
        var candidates: [(name: String, suffix: String)]
        let base: String
        if isCommand && !word.contains("/") {
            base = ""
            candidates = Self.commandNames.filter { $0.hasPrefix(word) }.map { ($0, " ") }
        } else {
            let dirPart = word.lastIndex(of: "/").map { String(word[...$0]) } ?? ""
            let namePart = String(word.dropFirst(dirPart.count))
            base = dirPart
            let dir = DemoFileSystem.normalize(dirPart.isEmpty ? "." : dirPart, cwd: cwd)
            let entries = (try? fs.children(of: dir)) ?? []
            candidates = entries
                .filter { $0.name.hasPrefix(namePart) && (namePart.hasPrefix(".") || !$0.name.hasPrefix(".")) }
                .map { ($0.name, $0.node.isDirectory ? "/" : " ") }
        }
        guard !candidates.isEmpty else { return "\u{7}" }
        let typed = String(word.dropFirst(base.count))
        if candidates.count == 1 {
            let c = candidates[0]
            insert(String(c.name.dropFirst(typed.count)) + c.suffix)
            return redraw()
        }
        let common = candidates.map(\.name).reduce(candidates[0].name) { $0.commonPrefix(with: $1) }
        if common.count > typed.count {
            insert(String(common.dropFirst(typed.count)))
            return redraw()
        }
        let listing = candidates.map { $0.name + ($0.suffix == "/" ? "/" : "") }.joined(separator: "  ")
        return "\r\n" + listing + "\r\n" + promptSequence() + String(line) + cursorTail()
    }

    private func insert(_ text: String) {
        line.insert(contentsOf: text, at: cursor)
        cursor += text.count
    }

    // MARK: - 执行

    struct Result {
        var out = ""
        var err = ""
        var status: Int32 = 0
        var clear = false
        var exit = false
    }

    /// 执行一整行：`;` / `&&` / `||` 串起的若干管道。
    func execute(_ commandLine: String, tty: Bool) -> Result {
        var total = Result()
        let tokens: [DemoShellToken]
        do {
            tokens = try DemoShellToken.tokenize(commandLine)
        } catch {
            total.out = "bash: syntax error: unexpected end of file\n"
            total.status = 2
            lastStatus = 2
            return total
        }
        var pending: [DemoShellToken] = []
        var skip = false
        func flush() {
            defer { pending = [] }
            guard !pending.isEmpty else { return }
            if !skip {
                let r = runPipeline(pending, tty: tty)
                // 按发生的先后拼在一起（`nosuch; echo hi` 先看到报错再看到 hi），同终端里看到的一样。
                total.out += r.err + r.out
                total.clear = total.clear || r.clear
                total.status = r.status
                lastStatus = r.status
                if r.exit { total.exit = true }
            }
        }
        for token in tokens {
            if case .op(let op) = token, [";", "&&", "||"].contains(op) {
                flush()
                if total.exit { return total }
                switch op {
                case "&&": skip = lastStatus != 0
                case "||": skip = lastStatus == 0
                default: skip = false
                }
                continue
            }
            if case .op(let op) = token, op == "(" || op == ")" || op == "&" { continue }
            pending.append(token)
        }
        flush()
        return total
    }

    private func runPipeline(_ tokens: [DemoShellToken], tty: Bool) -> Result {
        let stages = tokens.split { if case .op("|") = $0 { return true } else { return false } }
        var stdin: String?
        var result = Result()
        for (index, stage) in stages.enumerated() {
            let isLast = index == stages.count - 1
            var args: [String] = []
            var stdoutTarget: (path: String, append: Bool)?
            var discardStderr = false
            var iterator = stage.makeIterator()
            while let token = iterator.next() {
                switch token {
                case .word(let w):
                    args.append(contentsOf: expand(w))
                case .op(let op) where op == ">" || op == ">>":
                    guard case .word(let w)? = iterator.next() else {
                        return Result(err: "bash: syntax error near unexpected token `newline'\n", status: 2)
                    }
                    stdoutTarget = (expand(w).first ?? "", op == ">>")
                case .op(let op) where op == "2>" || op == "2>>":
                    if case .word(let w)? = iterator.next(), expand(w).first == "/dev/null" { discardStderr = true }
                case .op("2>&1"), .op("&>"):
                    continue
                default:
                    continue
                }
            }
            let toTTY = tty && isLast && stdoutTarget == nil
            var r = runCommand(args, stdin: stdin, tty: toTTY)
            if discardStderr { r.err = "" }
            if let target = stdoutTarget {
                if target.path == "/dev/null" {
                    r.out = ""
                } else {
                    let path = DemoFileSystem.normalize(target.path, cwd: cwd)
                    do {
                        try fs.write(path, data: Data(r.out.utf8), append: target.append, now: now())
                    } catch let e as DemoFSError {
                        r.err += "bash: \(target.path): \(e.reason)\n"
                        r.status = 1
                    } catch {}
                    r.out = ""
                }
            }
            result.err += r.err
            result.clear = result.clear || r.clear
            result.exit = result.exit || r.exit
            result.status = r.status
            if isLast { result.out = r.out } else { stdin = r.out }
        }
        return result
    }

    /// 展开 `$VAR` / `~` / 通配符。引号里的部分不展开通配符，单引号里也不展开变量（由词法阶段标好）。
    private func expand(_ word: DemoShellWord) -> [String] {
        var text = ""
        var globbable = false
        for part in word.parts {
            switch part.quoting {
            case .single:
                text += part.text
            case .double:
                text += expandVariables(part.text)
            case .none:
                var piece = expandVariables(part.text)
                if text.isEmpty, piece == "~" || piece.hasPrefix("~/") { piece = DemoFileSystem.home + piece.dropFirst() }
                if piece.contains("*") || piece.contains("?") { globbable = true }
                text += piece
            }
        }
        guard globbable else { return [text] }
        let matches = glob(text)
        return matches.isEmpty ? [text] : matches
    }

    private func expandVariables(_ text: String) -> String {
        guard text.contains("$") else { return text }
        var out = ""
        var chars = Array(text)[...]
        while let c = chars.popFirst() {
            guard c == "$", let next = chars.first else { out.append(c); continue }
            if next == "?" { chars.removeFirst(); out += String(lastStatus); continue }
            var name = ""
            if next == "{" {
                chars.removeFirst()
                while let n = chars.popFirst(), n != "}" { name.append(n) }
            } else {
                while let n = chars.first, n.isLetter || n.isNumber || n == "_" { name.append(n); chars.removeFirst() }
            }
            if name.isEmpty { out.append("$") } else { out += env[name] ?? "" }
        }
        return out
    }

    /// 只展开最后一段（`*.txt`、`logs/*.log`）。
    private func glob(_ pattern: String) -> [String] {
        let dirPart = pattern.lastIndex(of: "/").map { String(pattern[...$0]) } ?? ""
        let namePattern = String(pattern.dropFirst(dirPart.count))
        guard !dirPart.contains("*"), !dirPart.contains("?") else { return [] }
        let dir = DemoFileSystem.normalize(dirPart.isEmpty ? "." : dirPart, cwd: cwd)
        let entries = (try? fs.children(of: dir)) ?? []
        return entries
            .filter { (namePattern.hasPrefix(".") || !$0.name.hasPrefix(".")) && Self.wildcard(namePattern, matches: $0.name) }
            .map { dirPart + $0.name }
    }

    // MARK: - 命令

    static let commandNames: [String] = [
        "cat", "cd", "chmod", "clear", "cp", "date", "df", "echo", "env", "exit", "export", "false", "find",
        "free", "grep", "head", "help", "history", "hostname", "id", "ls", "mkdir", "mv", "ps", "pwd", "rm",
        "rmdir", "stat", "tail", "touch", "tree", "true", "uname", "uptime", "wc", "which", "whoami",
    ].sorted()

    private func runCommand(_ args: [String], stdin: String?, tty: Bool) -> Result {
        guard let name = args.first else { return Result() }
        let rest = Array(args.dropFirst())
        if name.contains("=") && !name.hasPrefix("=") && rest.isEmpty {
            let (k, v) = Self.splitAssignment(name)
            env[k] = v
            return Result()
        }
        switch name {
        case "help": return Result(out: Self.helpText())
        case "pwd": return Result(out: cwd + "\n")
        case "cd": return cd(rest)
        case "ls", "ll", "la": return ls(name == "ls" ? rest : ["-l"] + (name == "la" ? ["-a"] : []) + rest, tty: tty)
        case "cat": return cat(rest, stdin: stdin)
        case "head", "tail": return headTail(name, rest, stdin: stdin)
        case "echo": return echo(rest)
        case "mkdir": return mkdir(rest)
        case "touch": return touch(rest)
        case "rm": return rm(rest)
        case "rmdir": return rmdir(rest)
        case "mv": return mv(rest)
        case "cp": return cp(rest)
        case "chmod": return chmod(rest)
        case "tree": return tree(rest, tty: tty)
        case "grep": return grep(rest, stdin: stdin, tty: tty)
        case "wc": return wc(rest, stdin: stdin)
        case "find": return find(rest)
        case "stat": return stat(rest)
        case "clear", "reset": return Result(clear: true)
        case "whoami": return Result(out: DemoFileSystem.user + "\n")
        case "id": return Result(out: "uid=1000(demo) gid=1000(demo) groups=1000(demo)\n")
        case "hostname": return Result(out: DemoFileSystem.hostname + "\n")
        case "uname": return uname(rest)
        case "date": return Result(out: Self.dateFormatter("EEE MMM d HH:mm:ss zzz yyyy").string(from: now()) + "\n")
        case "uptime": return uptime()
        case "env", "printenv":
            return Result(out: env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n") + "\n")
        case "export":
            for arg in rest where arg.contains("=") { let (k, v) = Self.splitAssignment(arg); env[k] = v }
            return Result()
        case "history":
            return Result(out: history.enumerated().map { String(format: "%5ld  ", $0.offset + 1) + $0.element }
                .joined(separator: "\n") + (history.isEmpty ? "" : "\n"))
        case "which":
            var r = Result()
            for arg in rest {
                if Self.commandNames.contains(arg) { r.out += "/usr/bin/\(arg)\n" } else { r.status = 1 }
            }
            return r
        case "ps":
            return Result(out: "    PID TTY          TIME CMD\n   1042 pts/0    00:00:00 bash\n   1187 pts/0    00:00:00 ps\n")
        case "df":
            return Result(out: """
                Filesystem     1K-blocks    Used Available Use% Mounted on
                /dev/vda1       41152736 6321480  32717776  17% /

                """)
        case "free":
            return Result(out: """
                               total        used        free      shared  buff/cache   available
                Mem:         4026532      812344     2184208        1220     1029980     2962832
                Swap:              0           0           0

                """)
        case "true", ":": return Result()
        case "false": return Result(status: 1)
        case "exit", "logout": return Result(exit: true)
        case "sudo", "su":
            return Result(err: "\(DemoFileSystem.user) is not in the sudoers file.\n", status: 1)
        case "vi", "vim", "nano", "emacs", "top", "htop", "less", "more", "man", "tmux", "screen":
            return Result(err: String(localized: "\(name)：体验主机不支持全屏程序。连接你自己的服务器就能用了。") + "\n", status: 1)
        case "ssh", "curl", "wget", "ping", "git", "apt", "apt-get", "yum", "dnf", "brew", "pip", "npm", "docker":
            return Result(err: String(localized: "\(name)：体验主机不联网。连接你自己的服务器就能用了。") + "\n", status: 1)
        default:
            return Result(err: "bash: \(name): command not found\n", status: 127)
        }
    }

    private func fsError(_ cmd: String, _ arg: String, _ error: Error) -> String {
        let reason = (error as? DemoFSError)?.reason ?? error.localizedDescription
        if case .omittingDirectory? = error as? DemoFSError { return "\(cmd): -r not specified; omitting directory '\(arg)'\n" }
        return "\(cmd): \(arg): \(reason)\n"
    }

    /// 拆 `-la` 这样的短选项。`--` 之后全当参数。
    private static func parseFlags(_ args: [String], valued: Set<Character> = []) -> (flags: Set<Character>, values: [Character: String], operands: [String]) {
        var flags = Set<Character>()
        var values: [Character: String] = [:]
        var operands: [String] = []
        var iterator = args.makeIterator()
        var onlyOperands = false
        while let arg = iterator.next() {
            if onlyOperands || !arg.hasPrefix("-") || arg == "-" { operands.append(arg); continue }
            if arg == "--" { onlyOperands = true; continue }
            if arg.hasPrefix("--") { continue }
            var chars = Array(arg.dropFirst())[...]
            while let c = chars.popFirst() {
                if valued.contains(c) {
                    values[c] = chars.isEmpty ? (iterator.next() ?? "") : String(chars)
                    break
                }
                flags.insert(c)
            }
        }
        return (flags, values, operands)
    }

    private func cd(_ args: [String]) -> Result {
        let target = args.first ?? DemoFileSystem.home
        let path = target == "-" ? (env["OLDPWD"] ?? cwd) : DemoFileSystem.normalize(target, cwd: cwd)
        guard let node = fs.node(at: path) else { return Result(err: "bash: cd: \(target): No such file or directory\n", status: 1) }
        guard node.isDirectory else { return Result(err: "bash: cd: \(target): Not a directory\n", status: 1) }
        env["OLDPWD"] = cwd
        cwd = path
        env["PWD"] = path
        return Result(out: target == "-" ? path + "\n" : "")
    }

    private func ls(_ args: [String], tty: Bool) -> Result {
        let (flags, _, operands) = Self.parseFlags(args)
        let long = flags.contains("l")
        let all = flags.contains("a") || flags.contains("A")
        let human = flags.contains("h")
        var r = Result()
        let targets = operands.isEmpty ? ["."] : operands
        var sections: [String] = []
        for target in targets {
            let path = DemoFileSystem.normalize(target, cwd: cwd)
            guard let node = fs.node(at: path) else {
                r.err += "ls: cannot access '\(target)': No such file or directory\n"
                r.status = 2
                continue
            }
            var entries: [(name: String, node: DemoFileSystem.Node)]
            if node.isDirectory {
                entries = ((try? fs.children(of: path)) ?? []).filter { all || !$0.name.hasPrefix(".") }
            } else {
                entries = [(target, node)]
            }
            var text = targets.count > 1 && node.isDirectory ? "\(target):\n" : ""
            if long {
                if node.isDirectory { text += "total \(entries.count * 4)\n" }
                text += entries.map { longLine($0.name, $0.node, human: human, tty: tty) }.joined()
            } else if tty {
                text += entries.isEmpty ? "" : entries.map { colorize($0.name, $0.node) }.joined(separator: "  ") + "\n"
            } else {
                text += entries.map { $0.name + "\n" }.joined()
            }
            sections.append(text)
        }
        r.out = sections.joined(separator: targets.count > 1 ? "\n" : "")
        return r
    }

    private func longLine(_ name: String, _ node: DemoFileSystem.Node, human: Bool, tty: Bool) -> String {
        let type = node.isDirectory ? "d" : "-"
        let size = human ? Self.humanSize(node.size) : String(node.size)
        let date = Self.lsDate(node.mtime, now: now())
        let shown = tty ? colorize(name, node) : name
        return "\(type)\(Self.permissionString(node.mode)) \(node.isDirectory ? 2 : 1) demo demo "
            + size.leftPadded(to: human ? 5 : 6) + " \(date) \(shown)\n"
    }

    private func colorize(_ name: String, _ node: DemoFileSystem.Node) -> String {
        if node.isDirectory { return "\u{1b}[1;34m\(name)\u{1b}[0m" }
        if node.mode & 0o111 != 0 { return "\u{1b}[1;32m\(name)\u{1b}[0m" }
        return name
    }

    private func readInputs(_ cmd: String, _ files: [String], stdin: String?) -> (text: String, err: String, status: Int32) {
        guard !files.isEmpty else { return (stdin ?? "", "", 0) }
        var text = "", err = ""
        var status: Int32 = 0
        for file in files {
            if file == "-" { text += stdin ?? ""; continue }
            let path = DemoFileSystem.normalize(file, cwd: cwd)
            do {
                text += String(decoding: try fs.read(path), as: UTF8.self)
            } catch {
                err += fsError(cmd, file, error)
                status = 1
            }
        }
        return (text, err, status)
    }

    private func cat(_ args: [String], stdin: String?) -> Result {
        let (flags, _, files) = Self.parseFlags(args)
        let input = readInputs("cat", files, stdin: stdin)
        var text = input.text
        if flags.contains("n") {
            text = Self.lines(text).enumerated().map { String(format: "%6ld\t", $0.offset + 1) + $0.element + "\n" }.joined()
        }
        return Result(out: text, err: input.err, status: input.status)
    }

    private func headTail(_ cmd: String, _ args: [String], stdin: String?) -> Result {
        var normalized = args
        if let i = normalized.firstIndex(where: { $0.count > 1 && $0.hasPrefix("-") && Int($0.dropFirst()) != nil }) {
            normalized[i] = "-n" + normalized[i].dropFirst()
        }
        let (_, values, files) = Self.parseFlags(normalized, valued: ["n"])
        let count = values["n"].flatMap { Int($0.trimmingCharacters(in: CharacterSet(charactersIn: "+"))) } ?? 10
        let input = readInputs(cmd, files, stdin: stdin)
        let lines = Self.lines(input.text)
        let picked = cmd == "head" ? lines.prefix(count) : lines.suffix(count)
        return Result(out: picked.map { $0 + "\n" }.joined(), err: input.err, status: input.status)
    }

    private func echo(_ args: [String]) -> Result {
        var args = args
        var newline = true
        var escapes = false
        while let first = args.first, first.hasPrefix("-"), first.count > 1, first.dropFirst().allSatisfy({ "neE".contains($0) }) {
            if first.contains("n") { newline = false }
            if first.contains("e") { escapes = true }
            args.removeFirst()
        }
        var text = args.joined(separator: " ")
        if escapes { text = text.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\t", with: "\t") }
        return Result(out: text + (newline ? "\n" : ""))
    }

    private func mkdir(_ args: [String]) -> Result {
        let (flags, _, dirs) = Self.parseFlags(args)
        guard !dirs.isEmpty else { return Result(err: "mkdir: missing operand\n", status: 1) }
        var r = Result()
        for dir in dirs {
            do {
                try fs.mkdir(DemoFileSystem.normalize(dir, cwd: cwd), parents: flags.contains("p"), now: now())
            } catch let e as DemoFSError where e.reason == "File exists" {
                r.err += "mkdir: cannot create directory '\(dir)': File exists\n"; r.status = 1
            } catch {
                r.err += "mkdir: cannot create directory '\(dir)': \((error as? DemoFSError)?.reason ?? "")\n"; r.status = 1
            }
        }
        return r
    }

    private func touch(_ args: [String]) -> Result {
        let (_, _, files) = Self.parseFlags(args)
        guard !files.isEmpty else { return Result(err: "touch: missing file operand\n", status: 1) }
        var r = Result()
        for file in files {
            do { try fs.touch(DemoFileSystem.normalize(file, cwd: cwd), now: now()) } catch {
                r.err += "touch: cannot touch '\(file)': \((error as? DemoFSError)?.reason ?? "")\n"; r.status = 1
            }
        }
        return r
    }

    private func rm(_ args: [String]) -> Result {
        let (flags, _, files) = Self.parseFlags(args)
        let recursive = flags.contains("r") || flags.contains("R")
        let force = flags.contains("f")
        guard !files.isEmpty else { return force ? Result() : Result(err: "rm: missing operand\n", status: 1) }
        var r = Result()
        for file in files {
            let path = DemoFileSystem.normalize(file, cwd: cwd)
            do { try fs.remove(path, recursive: recursive) } catch {
                if force, case .noSuchFile? = error as? DemoFSError { continue }
                if case .isDirectory? = error as? DemoFSError {
                    r.err += "rm: cannot remove '\(file)': Is a directory\n"
                } else {
                    r.err += "rm: cannot remove '\(file)': \((error as? DemoFSError)?.reason ?? "")\n"
                }
                r.status = 1
            }
        }
        return r
    }

    private func rmdir(_ args: [String]) -> Result {
        var r = Result()
        for dir in args where !dir.hasPrefix("-") {
            let path = DemoFileSystem.normalize(dir, cwd: cwd)
            guard fs.isDirectory(path) else {
                r.err += "rmdir: failed to remove '\(dir)': \(fs.node(at: path) == nil ? "No such file or directory" : "Not a directory")\n"
                r.status = 1
                continue
            }
            do { try fs.remove(path, allowEmptyDirectory: true) } catch {
                r.err += "rmdir: failed to remove '\(dir)': \((error as? DemoFSError)?.reason ?? "")\n"; r.status = 1
            }
        }
        return r
    }

    private func mv(_ args: [String]) -> Result {
        let (_, _, operands) = Self.parseFlags(args)
        guard operands.count >= 2 else { return Result(err: "mv: missing destination file operand\n", status: 1) }
        let dest = DemoFileSystem.normalize(operands.last!, cwd: cwd)
        var r = Result()
        for source in operands.dropLast() {
            do { try fs.move(DemoFileSystem.normalize(source, cwd: cwd), to: dest, now: now()) } catch {
                r.err += "mv: cannot move '\(source)': \((error as? DemoFSError)?.reason ?? "")\n"; r.status = 1
            }
        }
        return r
    }

    private func cp(_ args: [String]) -> Result {
        let (flags, _, operands) = Self.parseFlags(args)
        guard operands.count >= 2 else { return Result(err: "cp: missing destination file operand\n", status: 1) }
        let dest = DemoFileSystem.normalize(operands.last!, cwd: cwd)
        var r = Result()
        for source in operands.dropLast() {
            do {
                try fs.copy(DemoFileSystem.normalize(source, cwd: cwd), to: dest,
                            recursive: flags.contains("r") || flags.contains("R") || flags.contains("a"), now: now())
            } catch {
                r.err += fsError("cp", source, error); r.status = 1
            }
        }
        return r
    }

    private func chmod(_ args: [String]) -> Result {
        let recursive = args.contains("-R")
        let operands = args.filter { $0 != "-R" && $0 != "-v" && $0 != "-f" }
        guard operands.count >= 2 else { return Result(err: "chmod: missing operand\n", status: 1) }
        var r = Result()
        for file in operands.dropFirst() {
            let path = DemoFileSystem.normalize(file, cwd: cwd)
            guard let node = fs.node(at: path) else {
                r.err += "chmod: cannot access '\(file)': No such file or directory\n"; r.status = 1; continue
            }
            guard let mode = Self.parseMode(operands[0], current: node.mode) else {
                return Result(err: "chmod: invalid mode: '\(operands[0])'\n", status: 1)
            }
            try? fs.chmod(path, mode: mode, recursive: recursive)
        }
        return r
    }

    private func tree(_ args: [String], tty: Bool) -> Result {
        let (flags, _, operands) = Self.parseFlags(args)
        let root = operands.first ?? "."
        let path = DemoFileSystem.normalize(root, cwd: cwd)
        guard fs.isDirectory(path) else { return Result(err: "\(root) [error opening dir]\n", status: 2) }
        var out = (tty ? "\u{1b}[1;34m\(root)\u{1b}[0m" : root) + "\n"
        var dirs = 0, files = 0
        func walk(_ dir: String, _ indent: String) {
            let entries = ((try? fs.children(of: dir)) ?? []).filter { flags.contains("a") || !$0.name.hasPrefix(".") }
            for (i, entry) in entries.enumerated() {
                let last = i == entries.count - 1
                out += indent + (last ? "└── " : "├── ") + (tty ? colorize(entry.name, entry.node) : entry.name) + "\n"
                if entry.node.isDirectory {
                    dirs += 1
                    walk((dir == "/" ? "" : dir) + "/" + entry.name, indent + (last ? "    " : "│   "))
                } else {
                    files += 1
                }
            }
        }
        walk(path, "")
        out += "\n\(dirs) director\(dirs == 1 ? "y" : "ies"), \(files) file\(files == 1 ? "" : "s")\n"
        return Result(out: out)
    }

    private func grep(_ args: [String], stdin: String?, tty: Bool) -> Result {
        let (flags, _, operands) = Self.parseFlags(args)
        guard let pattern = operands.first else { return Result(err: "Usage: grep [OPTION]... PATTERNS [FILE]...\n", status: 2) }
        var files = Array(operands.dropFirst())
        if flags.contains("r") || flags.contains("R") {
            let roots = files.isEmpty ? ["."] : files
            files = roots.flatMap { root -> [String] in
                let path = DemoFileSystem.normalize(root, cwd: cwd)
                return fs.walk(path).filter { !fs.isDirectory($0) }.map { p in
                    root == "." ? String(p.dropFirst(cwd == "/" ? 1 : cwd.count + 1)) : root + p.dropFirst(path.count)
                }
            }
        }
        let regex = try? NSRegularExpression(pattern: pattern, options: flags.contains("i") ? [.caseInsensitive] : [])
        func matches(_ line: String) -> Bool {
            let hit: Bool
            if let regex {
                hit = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
            } else {
                hit = flags.contains("i") ? line.localizedCaseInsensitiveContains(pattern) : line.contains(pattern)
            }
            return hit != flags.contains("v")
        }
        var r = Result(status: 1)
        let showNames = files.count > 1
        let sources: [(name: String?, text: String)]
        if files.isEmpty {
            sources = [(nil, stdin ?? "")]
        } else {
            sources = files.compactMap { file in
                let path = DemoFileSystem.normalize(file, cwd: cwd)
                guard let data = try? fs.read(path) else {
                    r.err += "grep: \(file): \(fs.isDirectory(path) ? "Is a directory" : "No such file or directory")\n"
                    return nil
                }
                return (file, String(decoding: data, as: UTF8.self))
            }
        }
        for source in sources {
            for (i, line) in Self.lines(source.text).enumerated() where matches(line) {
                r.status = 0
                if flags.contains("l") { r.out += (source.name ?? "(standard input)") + "\n"; break }
                var prefix = ""
                if showNames, let name = source.name { prefix += (tty ? "\u{1b}[35m\(name)\u{1b}[36m:\u{1b}[0m" : name + ":") }
                if flags.contains("n") { prefix += (tty ? "\u{1b}[32m\(i + 1)\u{1b}[36m:\u{1b}[0m" : "\(i + 1):") }
                r.out += prefix + line + "\n"
            }
        }
        if flags.contains("c") {
            r.out = String(Self.lines(r.out).count) + "\n"
        }
        return r
    }

    private func wc(_ args: [String], stdin: String?) -> Result {
        let (flags, _, files) = Self.parseFlags(args)
        let input = readInputs("wc", files, stdin: stdin)
        let lineCount = input.text.filter { $0 == "\n" }.count
        let words = input.text.split(whereSeparator: \.isWhitespace).count
        let bytes = input.text.utf8.count
        var parts: [String] = []
        let all = flags.isEmpty
        if all || flags.contains("l") { parts.append(String(lineCount)) }
        if all || flags.contains("w") { parts.append(String(words)) }
        if all || flags.contains("c") { parts.append(String(bytes)) }
        var out = parts.joined(separator: " ")
        if files.count == 1 { out += " " + files[0] }
        return Result(out: out + "\n", err: input.err, status: input.status)
    }

    /// 只认文件页搜索用到的那几个谓词：`-maxdepth`、`-mindepth`、`-type f|d`、`-name` / `-iname`、`-printf '%y\t%p\n'`。
    private func find(_ args: [String]) -> Result {
        var roots: [String] = []
        var maxDepth = Int.max, minDepth = 0
        var types: Set<String> = []
        var namePattern: (String, Bool)?
        var printf: String?
        var iterator = args.makeIterator()
        while let arg = iterator.next() {
            switch arg {
            case "-maxdepth": maxDepth = Int(iterator.next() ?? "") ?? maxDepth
            case "-mindepth": minDepth = Int(iterator.next() ?? "") ?? minDepth
            case "-type": if let t = iterator.next() { types.insert(t) }
            case "-name": namePattern = (iterator.next() ?? "*", false)
            case "-iname": namePattern = (iterator.next() ?? "*", true)
            case "-printf": printf = iterator.next()
            case "-print", "-o", "-or", "(", ")", "!": continue
            default:
                if arg.hasPrefix("-") { continue }
                roots.append(arg)
            }
        }
        if roots.isEmpty { roots = ["."] }
        var r = Result()
        for root in roots {
            let base = DemoFileSystem.normalize(root, cwd: cwd)
            guard fs.node(at: base) != nil else {
                r.err += "find: '\(root)': No such file or directory\n"; r.status = 1; continue
            }
            let baseDepth = base == "/" ? 0 : base.split(separator: "/").count
            for path in fs.walk(base) {
                guard let node = fs.node(at: path) else { continue }
                let depth = (path == "/" ? 0 : path.split(separator: "/").count) - baseDepth
                guard depth >= minDepth, depth <= maxDepth else { continue }
                if !types.isEmpty, !types.contains(node.isDirectory ? "d" : "f") { continue }
                let name = DemoFileSystem.name(of: path)
                if let (pattern, insensitive) = namePattern,
                   !Self.wildcard(insensitive ? pattern.lowercased() : pattern, matches: insensitive ? name.lowercased() : name) { continue }
                let shown = root + path.dropFirst(base.count)
                if let printf {
                    r.out += printf
                        .replacingOccurrences(of: "%y", with: node.isDirectory ? "d" : "f")
                        .replacingOccurrences(of: "%p", with: shown)
                        .replacingOccurrences(of: "\\t", with: "\t")
                        .replacingOccurrences(of: "\\n", with: "\n")
                } else {
                    r.out += shown + "\n"
                }
            }
        }
        return r
    }

    private func stat(_ args: [String]) -> Result {
        let (_, _, files) = Self.parseFlags(args, valued: ["c", "f"])
        var r = Result()
        for file in files {
            let path = DemoFileSystem.normalize(file, cwd: cwd)
            guard let node = fs.node(at: path) else {
                r.err += "stat: cannot statx '\(file)': No such file or directory\n"; r.status = 1; continue
            }
            r.out += """
                  File: \(file)
                  Size: \(node.size)\t\t\(node.isDirectory ? "directory" : "regular file")
                Access: (0\(String(node.mode, radix: 8))/\(node.isDirectory ? "d" : "-")\(Self.permissionString(node.mode)))  Uid: ( 1000/    demo)   Gid: ( 1000/    demo)
                Modify: \(Self.dateFormatter("yyyy-MM-dd HH:mm:ss").string(from: node.mtime))

                """
        }
        return r
    }

    private func uname(_ args: [String]) -> Result {
        let (flags, _, _) = Self.parseFlags(args)
        if flags.contains("a") {
            return Result(out: "Linux \(DemoFileSystem.hostname) 6.8.0-demo #1 SMP PREEMPT_DYNAMIC aarch64 GNU/Linux\n")
        }
        var parts: [String] = []
        if flags.isEmpty || flags.contains("s") { parts.append("Linux") }
        if flags.contains("n") { parts.append(DemoFileSystem.hostname) }
        if flags.contains("r") { parts.append("6.8.0-demo") }
        if flags.contains("m") { parts.append("aarch64") }
        return Result(out: parts.joined(separator: " ") + "\n")
    }

    private func uptime() -> Result {
        let minutes = Int(now().timeIntervalSince(startedAt) / 60)
        let time = Self.dateFormatter("HH:mm:ss").string(from: now())
        return Result(out: " \(time) up \(minutes) min,  1 user,  load average: 0.08, 0.03, 0.01\n")
    }

    // MARK: - 小工具

    static func helpText() -> String {
        String(localized: """
            体验主机支持这些命令：
              ls [-la]  cd  pwd  tree  find
              cat  head  tail  grep [-inrv]  wc
              echo（支持 > 与 >> 重定向）  touch  mkdir [-p]
              cp [-r]  mv  rm [-rf]  rmdir  chmod
              whoami  hostname  uname -a  date  uptime  env  history  clear  exit
            也能用管道（cat notes.txt | grep TODO）和 &&、;。
            这些命令在这台设备的内存里执行，文件页里看到的是同一份文件。

            """)
    }

    static func crlf(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
    }

    static func lines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var parts = text.components(separatedBy: "\n")
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    static func splitAssignment(_ text: String) -> (String, String) {
        let eq = text.firstIndex(of: "=")!
        return (String(text[..<eq]), String(text[text.index(after: eq)...]))
    }

    static func permissionString(_ mode: UInt32) -> String {
        let bits = "rwxrwxrwx"
        return String(bits.enumerated().map { i, c in mode & (0o400 >> UInt32(i)) != 0 ? c : "-" })
    }

    /// 八进制（`755`）或符号（`u+x`、`go-w`、`a=r`、`+x`）。
    static func parseMode(_ text: String, current: UInt32) -> UInt32? {
        if let octal = UInt32(text, radix: 8), text.allSatisfy({ ("0"..."7").contains($0) }) { return octal & 0o777 }
        var mode = current & 0o777
        for clause in text.split(separator: ",") {
            guard let opIndex = clause.firstIndex(where: { "+-=".contains($0) }) else { return nil }
            let who = clause[..<opIndex].isEmpty ? "a" : clause[..<opIndex]
            let op = clause[opIndex]
            let perms = clause[clause.index(after: opIndex)...]
            var mask: UInt32 = 0
            for w in who {
                let shifts: [UInt32]
                switch w {
                case "u": shifts = [6]
                case "g": shifts = [3]
                case "o": shifts = [0]
                case "a": shifts = [6, 3, 0]
                default: return nil
                }
                for p in perms {
                    let bit: UInt32
                    switch p { case "r": bit = 4; case "w": bit = 2; case "x": bit = 1; default: return nil }
                    for s in shifts { mask |= bit << s }
                }
            }
            switch op {
            case "+": mode |= mask
            case "-": mode &= ~mask
            default:
                var whoMask: UInt32 = 0
                for w in who { whoMask |= w == "u" ? 0o700 : w == "g" ? 0o070 : w == "o" ? 0o007 : 0o777 }
                mode = (mode & ~whoMask) | mask
            }
        }
        return mode
    }

    /// `*` 与 `?` 的通配匹配（不支持方括号）。
    static func wildcard(_ pattern: String, matches name: String) -> Bool {
        let p = Array(pattern), n = Array(name)
        var pi = 0, ni = 0, star = -1, mark = 0
        while ni < n.count {
            if pi < p.count, p[pi] == "?" || p[pi] == n[ni] {
                pi += 1; ni += 1
            } else if pi < p.count, p[pi] == "*" {
                star = pi; mark = ni; pi += 1
            } else if star >= 0 {
                pi = star + 1; mark += 1; ni = mark
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    static func humanSize(_ bytes: Int) -> String {
        guard bytes >= 1024 else { return String(bytes) }
        let units = ["K", "M", "G"]
        var value = Double(bytes) / 1024
        var unit = 0
        while value >= 1024, unit < units.count - 1 { value /= 1024; unit += 1 }
        return value < 10 ? String(format: "%.1f%@", value, units[unit]) : "\(Int(value.rounded()))\(units[unit])"
    }

    static func dateFormatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }

    /// `ls -l` 的日期列：半年内写到分钟，更早的写年份。
    static func lsDate(_ date: Date, now: Date) -> String {
        let recent = abs(now.timeIntervalSince(date)) < 180 * 86_400
        return dateFormatter(recent ? "MMM dd HH:mm" : "MMM dd  yyyy").string(from: date)
    }

    static func width(_ c: Character) -> Int {
        guard let v = c.unicodeScalars.first?.value else { return 1 }
        let wide: [ClosedRange<UInt32>] = [
            0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F,
            0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x1F300...0x1FAFF, 0x20000...0x3FFFD,
        ]
        return wide.contains { $0.contains(v) } ? 2 : 1
    }

    static func width<S: Sequence>(_ chars: S) -> Int where S.Element == Character {
        chars.reduce(0) { $0 + width($1) }
    }
}

nonisolated private extension String {
    func leftPadded(to length: Int) -> String {
        count >= length ? self : String(repeating: " ", count: length - count) + self
    }
}

// MARK: - 词法

/// 一个词由若干段拼成，每段记着自己的引号方式（决定展开规则）：`"$HOME"/a*` = 双引号段 + 裸段。
nonisolated struct DemoShellWord: Equatable {
    enum Quoting: Equatable { case none, single, double }
    struct Part: Equatable {
        var text: String
        var quoting: Quoting
    }
    var parts: [Part] = []
}

nonisolated enum DemoShellToken: Equatable {
    case word(DemoShellWord)
    case op(String)

    struct UnterminatedQuote: Error {}

    static func tokenize(_ input: String) throws -> [DemoShellToken] {
        var tokens: [DemoShellToken] = []
        var word = DemoShellWord()
        var current = ""
        var inWord = false
        var chars = Array(input)[...]

        func flushPart(_ quoting: DemoShellWord.Quoting = .none) {
            guard !current.isEmpty || quoting != .none else { return }
            word.parts.append(.init(text: current, quoting: quoting))
            current = ""
        }
        func flushWord() {
            flushPart()
            if inWord { tokens.append(.word(word)) }
            word = DemoShellWord()
            inWord = false
        }

        while let c = chars.popFirst() {
            switch c {
            case " ", "\t":
                flushWord()
            case "\\":
                inWord = true
                if let next = chars.popFirst() { current.append(next) }
            case "'":
                flushPart()
                inWord = true
                var text = ""
                var closed = false
                while let n = chars.popFirst() { if n == "'" { closed = true; break }; text.append(n) }
                guard closed else { throw UnterminatedQuote() }
                current = text
                flushPart(.single)
            case "\"":
                flushPart()
                inWord = true
                var text = ""
                var closed = false
                while let n = chars.popFirst() {
                    if n == "\"" { closed = true; break }
                    if n == "\\", let e = chars.first, "\"\\$`".contains(e) { text.append(chars.removeFirst()); continue }
                    text.append(n)
                }
                guard closed else { throw UnterminatedQuote() }
                current = text
                flushPart(.double)
            case "#" where !inWord:
                chars = []
            case "|", "&", ";", ">", "<", "(", ")":
                if c == ">", current == "2" || current == "1", word.parts.isEmpty {
                    let fd = current
                    current = ""
                    inWord = false
                    var op = fd + ">"
                    if chars.first == ">" { op += ">"; chars.removeFirst() }
                    if chars.first == "&" {
                        chars.removeFirst()
                        let target = chars.popFirst().map(String.init) ?? ""
                        op += "&" + target
                    }
                    tokens.append(.op(op == "1>" ? ">" : op == "1>>" ? ">>" : op))
                    continue
                }
                flushWord()
                var op = String(c)
                if let next = chars.first, (c == "|" || c == "&" || c == ">") && next == c {
                    op.append(next); chars.removeFirst()
                } else if c == "&", chars.first == ">" {
                    op = "&>"; chars.removeFirst()
                }
                tokens.append(.op(op))
            default:
                inWord = true
                current.append(c)
            }
        }
        flushWord()
        return tokens
    }
}
