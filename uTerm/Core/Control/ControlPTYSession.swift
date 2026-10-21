import Foundation
import SwiftTerm

// MARK: - 在 PTY 里跑指定命令

/// Citadel 只公开「PTY + shell」，没有「PTY + exec」，所以要跑指定命令只能把它**打**给
/// 登录 shell。直接打一整行有三个坑：
/// - 登录 shell 五花八门（bash / zsh / fish / tcsh），引号与 `!`、`\` 的规则各不相同；
/// - shell 起来之前 tty 处在规范模式，一行超过 `MAX_CANON`（macOS 1024 字节）会被截断；
/// - motd、提示符、回显会混在输出最前面。
///
/// 做法分两步：
/// 1. 先打一行**固定的**引导（远短于 1024 字节，只含各家 shell 都按字面理解的字符）：
///    `exec` 成 `/bin/sh`，关回显，打一个就绪标记，然后逐行读 base64 直到 `.`；
/// 2. 看到就绪标记后再把命令按 base64 分行写进去。此时回显已关，读完立刻恢复回显，再
///    `exec "$SHELL" -c` —— 与 `run`（sshd 用登录 shell `-c` 跑命令）同一个解释器，
///    命令自己的交互（`sudo` 的密码提示、`[Y/n]`）照常。
///
/// 就绪标记在引导行里写成 `__UTERM_PTY_""READY__`：PTY 回显的是这串原文，只有 sh 真正
/// 执行后打出来的才连在一起。于是「标记之前」的一切（motd、提示符、引导行的回显）都丢掉。
/// `exec` 让命令的退出码就是通道的退出码。
nonisolated enum ControlPTYCommand {
    static let readyMarker = Array("__UTERM_PTY_READY__".utf8)

    /// 引导行。开头的空格让 bash / zsh / fish 不把它记进历史。
    static let bootstrapLine = Data((
        " exec /bin/sh -c 'stty -echo 2>/dev/null; printf \"\\n%s\\n\" __UTERM_PTY_\"\"READY__; "
            + "s=; while IFS= read -r l; do [ \"$l\" = . ] && break; s=\"$s$l\"; done; stty echo 2>/dev/null; "
            + "c=$(printf %s \"$s\" | (base64 -d 2>/dev/null || base64 -D)); exec \"${SHELL:-/bin/sh}\" -c \"$c\"'\n"
    ).utf8)

    /// 就绪之后写进去的命令：base64 每行 76 字符，以单独一行 `.` 结束。
    static func payload(_ command: String) -> Data {
        let encoded = Data(command.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithLineFeed])
        return Data((encoded + "\n.\n").utf8)
    }
}

/// 在输出里找就绪标记：之前的字节丢掉，之后的照常交给下游。
nonisolated struct PTYBootstrapFilter {
    /// 等这么多字节还没等到标记就放弃（`.bashrc` 里自动起 tmux、或者在等输入）。
    static let limit = 256 * 1024

    private(set) var isReady = false
    private(set) var overflowed = false
    private var pending: [UInt8] = []

    /// 返回该交给下游的字节，以及这一块是不是刚好让会话就绪（调用方此时写 payload）。
    mutating func feed(_ data: Data) -> (deliver: Data, becameReady: Bool) {
        if isReady { return (data, false) }
        if overflowed { return (Data(), false) }
        pending.append(contentsOf: data)
        let marker = ControlPTYCommand.readyMarker
        if let start = Self.find(marker, in: pending) {
            var end = start + marker.count
            // 标记后面跟着 `\r\n`（onlcr）或 `\n`；换行还没到就再等一块。
            while end < pending.count, pending[end] == UInt8(ascii: "\r") { end += 1 }
            guard end < pending.count else { return (Data(), false) }
            if pending[end] == UInt8(ascii: "\n") { end += 1 }
            let rest = Data(pending[end...])
            pending = []
            isReady = true
            return (rest, true)
        }
        if pending.count > Self.limit {
            pending = []
            overflowed = true
        }
        return (Data(), false)
    }

    private static func find(_ needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard haystack.count >= needle.count else { return nil }
        var index = 0
        while index + needle.count <= haystack.count {
            if haystack[index] == needle[0],
               haystack[index..<(index + needle.count)].elementsEqual(needle) {
                return index
            }
            index += 1
        }
        return nil
    }
}

// MARK: - 输出 → 纯文本

/// 把 PTY 的字节流收成给模型读的纯文本：去掉控制序列（颜色、光标移动、标题……），
/// `\r\n` 当换行，单独的 `\r` 当「回到行首重写」（进度条只留最后一帧），退格删字。
///
/// 增量处理：末尾不完整的控制序列 / UTF-8 字符留着不消费（`consumed` 指到它之前），
/// 下次连同新到的字节一起处理。行内状态不跨调用保留 —— 一行被拆在两次读之间时，前半行
/// 已经交出去了，后半行的 `\r` 覆盖只作用于后半行。对「读输出」够用，要看准确的画面用
/// 虚拟终端的 `screen`。
nonisolated enum PTYTextCleaner {

    struct Result: Equatable {
        var text: String
        var consumed: Int
    }

    static func clean(_ data: Data, final: Bool = false) -> Result {
        let bytes = [UInt8](data)
        var out: [UInt8] = []
        var line: [UInt8] = []
        var index = 0
        var consumed = 0
        let count = bytes.count

        func flushLine(newline: Bool) {
            out.append(contentsOf: line)
            if newline { out.append(UInt8(ascii: "\n")) }
            line.removeAll(keepingCapacity: true)
        }

        scan: while index < count {
            let byte = bytes[index]
            switch byte {
            case 0x1B:
                guard let end = escapeEnd(bytes, from: index) else {
                    if final {
                        index = count
                        consumed = count
                        break scan
                    }
                    break scan
                }
                index = end
            case UInt8(ascii: "\n"):
                flushLine(newline: true)
                index += 1
            case UInt8(ascii: "\r"):
                if index + 1 < count {
                    if bytes[index + 1] != UInt8(ascii: "\n") {
                        line.removeAll(keepingCapacity: true)
                    }
                    index += 1
                } else if final {
                    index += 1
                } else {
                    break scan
                }
            case 0x08:
                // 退格：删掉一个完整的 UTF-8 字符。
                while let last = line.popLast(), last & 0xC0 == 0x80 {}
                index += 1
            case UInt8(ascii: "\t"):
                line.append(byte)
                index += 1
            case 0x00..<0x20, 0x7F:
                index += 1
            default:
                line.append(byte)
                index += 1
            }
            consumed = index
        }

        // 行尾不完整的 UTF-8 字符留到下一次。
        if !final, consumed == count {
            let hold = incompleteUTF8Suffix(line)
            if hold > 0 {
                line.removeLast(hold)
                consumed -= hold
            }
        }
        flushLine(newline: false)
        return Result(text: String(decoding: out, as: UTF8.self), consumed: consumed)
    }

    /// 从 `start`（ESC）开始的控制序列在哪儿结束（排他）。不完整返回 nil。
    private static func escapeEnd(_ bytes: [UInt8], from start: Int) -> Int? {
        let count = bytes.count
        guard start + 1 < count else { return nil }
        let kind = bytes[start + 1]
        switch kind {
        case UInt8(ascii: "["):
            // CSI：参数 0x30–0x3F、中间字节 0x20–0x2F，以 0x40–0x7E 结尾。
            var index = start + 2
            while index < count {
                let byte = bytes[index]
                if byte >= 0x40, byte <= 0x7E { return index + 1 }
                // 坏序列：在这个字节之前收尾，它自己照常处理（多半是换行之类）。
                if byte < 0x20 || byte > 0x7E { return index }
                index += 1
            }
            return nil
        case UInt8(ascii: "]"), UInt8(ascii: "P"), UInt8(ascii: "X"),
             UInt8(ascii: "^"), UInt8(ascii: "_"):
            // OSC / DCS / SOS / PM / APC：以 BEL（只有 OSC）或 ST（ESC \）结尾。
            var index = start + 2
            while index < count {
                if bytes[index] == 0x07, kind == UInt8(ascii: "]") { return index + 1 }
                if bytes[index] == 0x1B {
                    guard index + 1 < count else { return nil }
                    if bytes[index + 1] == UInt8(ascii: "\\") { return index + 2 }
                }
                index += 1
            }
            // 一直没结尾的超长串（坏数据）：别把后面的输出全吞了。
            return count - start > 4096 ? start + 2 : nil
        case UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "*"),
             UInt8(ascii: "+"), UInt8(ascii: "#"), UInt8(ascii: "%"):
            return start + 3 <= count ? start + 3 : nil
        default:
            return start + 2
        }
    }

    /// 末尾有几个字节属于一个还没收全的 UTF-8 字符。
    private static func incompleteUTF8Suffix(_ bytes: [UInt8]) -> Int {
        var back = 0
        var index = bytes.count - 1
        while index >= 0, back < 4 {
            let byte = bytes[index]
            back += 1
            if byte & 0xC0 == 0x80 {
                index -= 1
                continue
            }
            let need: Int
            if byte & 0xE0 == 0xC0 { need = 2 }
            else if byte & 0xF0 == 0xE0 { need = 3 }
            else if byte & 0xF8 == 0xF0 { need = 4 }
            else { return 0 }
            return back < need ? back : 0
        }
        return 0
    }
}

// MARK: - 按键名

nonisolated enum PTYKeys {
    static let named: [String: String] = [
        "enter": "\r", "return": "\r", "tab": "\t", "esc": "\u{1B}", "escape": "\u{1B}",
        "backspace": "\u{7F}", "space": " ", "delete": "\u{1B}[3~",
        "up": "\u{1B}[A", "down": "\u{1B}[B", "right": "\u{1B}[C", "left": "\u{1B}[D",
        "home": "\u{1B}[H", "end": "\u{1B}[F", "pageup": "\u{1B}[5~", "pagedown": "\u{1B}[6~",
    ]

    /// `enter` / `ctrl-c` / `up` … → 字节。认不出返回 nil。
    static func bytes(for name: String) -> String? {
        let key = name.lowercased().trimmingCharacters(in: .whitespaces)
        if let value = named[key] { return value }
        for prefix in ["ctrl-", "ctrl+", "c-", "^"] where key.hasPrefix(prefix) {
            let rest = key.dropFirst(prefix.count)
            guard rest.count == 1, let scalar = rest.unicodeScalars.first else { return nil }
            switch scalar {
            case "a"..."z":
                return String(UnicodeScalar(UInt8(scalar.value - 0x60)))
            case "[": return "\u{1B}"
            case "\\": return "\u{1C}"
            case "]": return "\u{1D}"
            case "@", " ": return "\u{00}"
            default: return nil
            }
        }
        return nil
    }

    static let help = "可用按键：enter tab esc backspace space delete up down left right home end "
        + "pageup pagedown，以及 ctrl-a … ctrl-z（ctrl-c 中断、ctrl-d 结束输入）"
}

// MARK: - 虚拟终端（读画面用）

/// 不显示的 SwiftTerm 终端：喂进输出，随时取「此刻屏幕上是什么」。程序向终端发的查询
/// （光标位置、设备属性）由它作答，答复经 `reply` 写回 PTY —— 有些程序等不到答复会卡住。
private nonisolated final class HeadlessScreen: TerminalDelegate {
    private(set) var terminal: Terminal!
    var reply: (@Sendable (Data) -> Void)?

    init(cols: Int, rows: Int) {
        terminal = Terminal(
            delegate: self,
            options: TerminalOptions(cols: cols, rows: rows, scrollback: 0)
        )
    }

    func send(source: Terminal, data: ArraySlice<UInt8>) {
        reply?(Data(data))
    }

    /// 屏幕各行（去右侧空白、去尾部空行）。
    func lines() -> [String] {
        var rows: [String] = []
        for row in 0..<terminal.rows {
            rows.append(Self.text(of: terminal.getLine(row: row)))
        }
        while let last = rows.last, last.isEmpty { rows.removeLast() }
        return rows
    }

    /// 光标所在行与光标列。
    func cursorLine() -> (text: String, column: Int) {
        let cursor = terminal.getCursorLocation()
        return (Self.text(of: terminal.getLine(row: cursor.y)), cursor.x)
    }

    /// `trimRight` 只去没写过的格子；程序真写出来的空格（`Password: `）要自己去。
    /// 光标跳过去的格子（右对齐的提示符）是 NUL，按空格算。
    private static func text(of line: BufferLine?) -> String {
        guard let line else { return "" }
        var text = line.translateToString(trimRight: true).replacingOccurrences(of: "\u{0}", with: " ")
        while let last = text.last, last == " " || last == "\t" { text.removeLast() }
        return text
    }
}

// MARK: - 会话

/// 命令行的一个交互会话：一条开在 CLI 连接池复用连接上的 PTY 通道，加上它的输出缓冲与
/// 虚拟终端。不在任何窗口里，用户看不见 —— 只有 `session-*` 能碰它。
///
/// 输出回调在 NIO 线程上，读写请求在 MainActor 上，所以是带锁的类。
nonisolated final class ControlPTYSession: @unchecked Sendable {

    /// 未读输出最多留多少字节；再多就从最旧的挤掉（`droppedBytes`）。
    static let maxBufferedBytes = 1 << 20

    let id: UUID
    let hostName: String
    let hostID: UUID
    let command: String?
    let spec: PTYSpec
    let startedAt: Date

    private let lock = NSLock()
    private var handle: (any PTYHandle)?
    private var bootstrap: PTYBootstrapFilter?
    private let screen: HeadlessScreen
    private var unread = Data()
    private var dropped = 0
    private var generation = 0
    private var lastOutputAt: ContinuousClock.Instant
    private var lastTouchedAt: Date
    private var ending: PTYEnding?
    private var endReason: String?
    private var endMessage: String?
    private var endedAt: Date?
    private var secrets: [String] = []

    init(id: UUID = UUID(), hostName: String, hostID: UUID, command: String?, spec: PTYSpec, now: Date = Date()) {
        self.id = id
        self.hostName = hostName
        self.hostID = hostID
        self.command = command
        self.spec = spec
        self.startedAt = now
        self.lastTouchedAt = now
        self.lastOutputAt = .now
        self.screen = HeadlessScreen(cols: spec.cols, rows: spec.rows)
        self.bootstrap = command == nil ? nil : PTYBootstrapFilter()
    }

    // MARK: 通道接线

    /// 通道开起来了。要跑指定命令的话，引导行在这里写进去。
    func attach(_ handle: any PTYHandle) {
        let closeNow: Bool = lock.withLock {
            self.handle = handle
            screen.reply = { [weak handle] data in handle?.write(data) }
            return ending != nil
        }
        if closeNow {
            handle.close()
            return
        }
        if command != nil { handle.write(ControlPTYCommand.bootstrapLine) }
    }

    /// 通道的输出回调。
    func ingest(_ data: Data) {
        var payload: Data?
        var giveUp = false
        var target: (any PTYHandle)?
        lock.withLock {
            target = handle
            var deliver = data
            if var filter = bootstrap {
                let step = filter.feed(data)
                deliver = step.deliver
                if step.becameReady, let command { payload = ControlPTYCommand.payload(command) }
                if filter.overflowed { giveUp = true }
                bootstrap = filter.isReady ? nil : filter
            }
            lastOutputAt = .now
            guard !deliver.isEmpty else { return }
            generation += 1
            screen.terminal.feed(byteArray: [UInt8](deliver))
            unread.append(deliver)
            if unread.count > Self.maxBufferedBytes {
                let cut = unread.count - Self.maxBufferedBytes
                unread.removeFirst(cut)
                dropped += cut
            }
        }
        if let payload { target?.write(payload) }
        if giveUp {
            end(reason: "failed", message: "登录 shell 输出了 \(PTYBootstrapFilter.limit / 1024) KiB 仍没有执行命令"
                + "（.bashrc / .zshrc 里自动起 tmux、或在等输入？）")
        }
    }

    /// 通道结束的回调。
    func finish(_ ending: PTYEnding) {
        lock.withLock {
            // 先 `end(reason:)` 过的（主动关）保留当时记下的原因。
            if self.ending == nil {
                self.ending = ending
                switch ending {
                case .exited: endReason = "exited"
                case .closedLocally: endReason = "closed"
                case .failed(let message):
                    endReason = "failed"
                    endMessage = message
                }
                endedAt = Date()
            }
            handle = nil
            screen.reply = nil
        }
    }

    /// 主动结束（`session-close`、自动回收、引导失败）。原因先记下，再关通道。
    func end(reason: String, message: String? = nil, at date: Date = Date()) {
        let toClose: (any PTYHandle)? = lock.withLock {
            guard ending == nil else { return nil }
            ending = .closedLocally
            endReason = reason
            endMessage = message
            endedAt = date
            let current = handle
            handle = nil
            screen.reply = nil
            return current
        }
        toClose?.close()
    }

    // MARK: 状态

    var isRunning: Bool { lock.withLock { ending == nil } }
    var isBootstrapping: Bool { lock.withLock { ending == nil && bootstrap != nil } }
    var endedAtDate: Date? { lock.withLock { endedAt } }
    var lastTouched: Date { lock.withLock { lastTouchedAt } }

    func touch(_ now: Date = Date()) {
        lock.withLock { lastTouchedAt = now }
    }

    /// 距离上一块输出过了多久（秒）。
    var quietSeconds: Double {
        let elapsed = lock.withLock { ContinuousClock.now - lastOutputAt }
        let parts = elapsed.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    var hasUnread: Bool { lock.withLock { !unread.isEmpty } }

    /// 每交付一块输出加一。`send` 之后据此判断「有没有新回话」。
    var outputGeneration: Int { lock.withLock { generation } }

    // MARK: 写入

    /// 写进 PTY。会话已经结束抛 `session_ended`。
    func write(_ text: String) throws(ControlFailure) {
        let current: (any PTYHandle)? = lock.withLock { ending == nil ? handle : nil }
        guard let current else {
            throw ControlFailure(code: .session_ended, message: "会话已经结束，写不进去了")
        }
        current.write(Data(text.utf8))
    }

    /// 用户在安全输入框里输的东西：写进 PTY，并记下来，之后的输出 / 画面里出现就打码。
    func writeSecret(_ secret: String) throws(ControlFailure) {
        lock.withLock { if !secret.isEmpty { secrets.append(secret) } }
        try write(secret + "\r")
    }

    func resize(cols: Int, rows: Int) {
        let current = lock.withLock { () -> (any PTYHandle)? in
            screen.terminal.resize(cols: cols, rows: rows)
            return handle
        }
        current?.resize(cols: cols, rows: rows)
    }

    // MARK: 读

    /// 未读输出的纯文本（不消费）—— 判 `waitFor` 用。
    func peekText() -> String {
        lock.withLock { scrub(PTYTextCleaner.clean(unread, final: ending != nil).text) }
    }

    /// 出一份快照。`consume` 时把未读输出收成 `output` 并清掉。
    func snapshot(
        consume: Bool,
        includeScreen: Bool,
        maxBytes: Int = ControlProtocol.maxSessionOutputBytes,
        matched: Bool? = nil
    ) -> ControlSessionSnapshot {
        let quiet = quietSeconds
        return lock.withLock {
            var output: String?
            var truncated = false
            if consume {
                let cleaned = PTYTextCleaner.clean(unread, final: ending != nil)
                unread.removeFirst(cleaned.consumed)
                var text = scrub(cleaned.text)
                if text.utf8.count > maxBytes {
                    text = Self.suffix(text, maxBytes: maxBytes)
                    truncated = true
                }
                output = text
            }
            let cursor = screen.cursorLine()
            let promptLine = scrub(cursor.text)
            let running = ending == nil
            var exitCode: Int?
            if case .exited(let code) = ending { exitCode = code }
            return ControlSessionSnapshot(
                id: id.uuidString,
                host: hostName,
                hostID: hostID.uuidString,
                command: command,
                term: spec.term,
                cols: screen.terminal.cols,
                rows: screen.terminal.rows,
                startedAt: ControlProtocol.iso8601(startedAt) ?? "",
                running: running,
                exitCode: exitCode,
                endReason: running ? nil : endReason,
                endMessage: running ? nil : endMessage,
                output: output,
                truncated: truncated,
                droppedBytes: dropped,
                screen: includeScreen ? screen.lines().map(scrub) : nil,
                promptLine: promptLine.isEmpty ? nil : promptLine,
                awaitingInput: running && bootstrap == nil && unread.isEmpty
                    && cursor.column > 0 && quiet >= ControlProtocol.sessionSettleSeconds,
                passwordPrompt: running && Self.looksLikePasswordPrompt(promptLine),
                matched: matched,
                quietSeconds: (quiet * 10).rounded() / 10
            )
        }
    }

    /// 只能在持锁时调。
    private func scrub(_ text: String) -> String {
        var result = text
        for secret in secrets where !secret.isEmpty {
            result = result.replacingOccurrences(of: secret, with: "********")
        }
        return result
    }

    private static func suffix(_ text: String, maxBytes: Int) -> String {
        var bytes = Array(text.utf8.suffix(maxBytes))
        // 别从一个多字节字符的中间切。
        while let first = bytes.first, first & 0xC0 == 0x80 { bytes.removeFirst() }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// `[sudo] password for alice:`、`Password:`、`Enter passphrase for key '…':`、`密码：`。
    static func looksLikePasswordPrompt(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix(":") || trimmed.hasSuffix("：") else { return false }
        let lowered = trimmed.lowercased()
        return ["password", "passphrase", "passcode", "密码", "口令", "pin"].contains { lowered.contains($0) }
    }
}

// MARK: - 登记处

/// 命令行开着的交互会话。上限、按 id 前缀找、到点回收。
@MainActor
final class ControlPTYSessions {
    static let shared = ControlPTYSessions()

    private var sessions: [ControlPTYSession] = []
    private var reaper: Task<Void, Never>?
    private let now: () -> Date

    init(now: @escaping () -> Date = { Date() }) {
        self.now = now
    }

    var all: [ControlPTYSession] { sessions }

    func add(_ session: ControlPTYSession) {
        sessions.append(session)
        scheduleReaper()
    }

    func remove(_ session: ControlPTYSession) {
        sessions.removeAll { $0 === session }
    }

    /// 还在跑的会话数（总数 / 某台主机）。
    func runningCount(hostID: UUID? = nil) -> Int {
        sessions.filter { $0.isRunning && (hostID == nil || $0.hostID == hostID) }.count
    }

    /// 完整 id 或唯一前缀（不分大小写）。
    func resolve(_ needle: String?) throws(ControlFailure) -> ControlPTYSession {
        guard let needle = needle?.trimmingCharacters(in: .whitespacesAndNewlines), !needle.isEmpty else {
            throw ControlFailure(code: .invalid_request, message: "缺少会话 id（`-s <id>`，先 `utermctl sessions` 看有哪些）")
        }
        let lowered = needle.lowercased()
        if let exact = sessions.first(where: { $0.id.uuidString.lowercased() == lowered }) {
            return exact
        }
        let matches = sessions.filter { $0.id.uuidString.lowercased().hasPrefix(lowered) }
        switch matches.count {
        case 1:
            return matches[0]
        case 0:
            throw ControlFailure(
                code: .session_not_found,
                message: "没有 id 以「\(needle)」开头的会话（结束 \(Int(ControlProtocol.endedSessionRetentionSeconds / 60)) 分钟后会被清掉）")
        default:
            throw ControlFailure(code: .session_ambiguous, message: "「\(needle)」匹配到 \(matches.count) 个会话，改用完整 id")
        }
    }

    /// 关掉全部（主开关关闭 / app 退出 / `disconnect` 不带主机）。
    func closeAll(reason: String = "closed", message: String? = nil) {
        for session in sessions { session.end(reason: reason, message: message) }
    }

    /// 关掉某台主机的全部（`disconnect -H`）。
    func close(hostID: UUID, reason: String = "closed", message: String? = nil) {
        for session in sessions where session.hostID == hostID {
            session.end(reason: reason, message: message)
        }
    }

    /// 回收：太久没人碰的、跑满总时长的关掉；结束够久的从表里删掉。返回剩几个。
    @discardableResult
    func reap() -> Int {
        let current = now()
        for session in sessions where session.isRunning {
            if current.timeIntervalSince(session.startedAt) >= ControlProtocol.sessionMaxSeconds {
                session.end(
                    reason: "max_duration",
                    message: "会话跑满 \(Int(ControlProtocol.sessionMaxSeconds / 3600)) 小时总时长上限，已关闭",
                    at: current)
            } else if current.timeIntervalSince(session.lastTouched) >= ControlProtocol.sessionIdleSeconds {
                session.end(
                    reason: "idle_timeout",
                    message: "\(Int(ControlProtocol.sessionIdleSeconds / 60)) 分钟没有任何 session 调用碰过它，已自动关闭",
                    at: current)
            }
        }
        sessions.removeAll { session in
            guard let ended = session.endedAtDate else { return false }
            return current.timeIntervalSince(ended) >= ControlProtocol.endedSessionRetentionSeconds
        }
        return sessions.count
    }

    private func scheduleReaper() {
        guard reaper == nil else { return }
        reaper = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self else { return }
                if self.reap() == 0 {
                    self.reaper = nil
                    return
                }
            }
        }
    }
}
