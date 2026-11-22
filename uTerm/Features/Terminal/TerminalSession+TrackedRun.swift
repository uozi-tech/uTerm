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
///
/// 用户看到的只有命令本身，包装不露出来：
/// - 等远端的行编辑器起来再打（`TrackedRunInjectionGate`）。早打的话终端驱动先把这行回显一遍，行编辑器起来又画一遍。
/// - 开始标记一到（这时行编辑器已经交出了那几行），本端把屏幕上回显的那一行改写成只剩命令
///   （`TrackedRunEchoRewrite`，经输出泵插在标记后面，影子、画面、远控镜像看到的一样）。
/// - 行首一个空格：开了 `HIST_IGNORE_SPACE` / `ignorespace` 的 shell 不把这行记进历史。
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
    /// 改写回显之后输出的第一行（改写删掉了几行，`startMarker` 跟不过去：vt 删行是换行内容，标记留在原来的格子上）。
    /// 在喂字节的线程上写，读的时候优先用它。
    let rewrittenStart = TrackedRunStartBox()
    var startedAt: Date?
    var finishedAt: Date?

    init(command: String, requestedAt: Date = Date()) {
        self.id = String(UUID().uuidString.prefix(8)).lowercased()
        self.command = command
        self.requestedAt = requestedAt
    }

    /// 打进 shell 的那一行（不含回车）。
    var inputLine: String { echoPrefix + command + echoSuffix }

    /// 回显出来的那一行里命令前面、后面的包装（行编辑器原样回显，`\033` 显示成四个字）。
    var echoPrefix: String { " printf '\\033]\(Self.oscCode);S;\(id)\\007'; (" }
    var echoSuffix: String { "); printf '\\033]\(Self.oscCode);D;\(id);%s\\007' \"$?\"" }

    /// 开始标记在字节流里的样子（`printf` 打出来的）。
    var startMarkerBytes: Data { Data("\u{1B}]\(Self.oscCode);S;\(id)\u{07}".utf8) }

    /// 只收单行命令：多行打进 shell 会变成续行提示，`$?` 也对不上。
    static func validate(_ command: String) -> String? {
        if command.contains("\n") || command.contains("\r") {
            return String(localized: "命令不能有换行：多条命令用 && 或 ; 连起来，长脚本先 sftp put 到主机上再跑")
        }
        if command.utf8.count > maxCommandBytes {
            return String(localized: "命令超过 \(maxCommandBytes) 字节：先把脚本 sftp put 到主机上再跑")
        }
        return nil
    }
}

/// 改写回显之后输出起点的标记。泵的线程写、主线程读。
nonisolated final class TrackedRunStartBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: ShadowTerminal.Marker?

    var marker: ShadowTerminal.Marker? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// 什么时候往远端 shell 里打命令。
nonisolated enum TrackedRunInjectionGate {
    /// 行编辑器一直没有信号（sh、bash 5.0 及以前不开括号粘贴，也没有 OSC 133）时，输出停这么久就当它在等输入。
    static let quietSeconds = 1.5
    /// 最多等这么久，到了照打。
    static let maxWaitSeconds = 6.0
    static let pollInterval: Duration = .milliseconds(50)

    /// - Parameters:
    ///   - lineEditorReady: 括号粘贴开着（zsh、bash 5.1+、fish 开始读一行时打开、跑命令前关掉），或者光标在 OSC 133 标的提示符里。
    ///   - sawOutput: 连上之后来过输出。
    ///   - quietFor: 离最后一次输出过了多久。
    ///   - waited: 一共等了多久。
    static func isReady(lineEditorReady: Bool, sawOutput: Bool, quietFor: Double, waited: Double) -> Bool {
        lineEditorReady || (sawOutput && quietFor >= quietSeconds) || waited >= maxWaitSeconds
    }
}

/// 把屏幕上回显的「包装 + 命令 + 包装」改写成只剩命令。
///
/// 开始标记到达时行编辑器已经交出了那几行，之后没人再回头画它们。做法：清掉包装占的那几行（从包装第一格起），
/// 删掉命令用不着的行（下面的内容跟着上移），在原处重写命令，光标放回（上移了几行就减几行）。
/// 字宽取自屏幕上回显的那一段（`EchoSpan.middleWidths`），所以折行位置和引擎排的一致。
nonisolated enum TrackedRunEchoRewrite {
    nonisolated struct Plan: Equatable, Sendable {
        var bytes: Data
        /// 改写后输出的第一行（活动区行号）。
        var outputRow: Int
    }

    static func plan(span: ShadowTerminal.EchoSpan, command: String) -> Plan? {
        // 控制字符行编辑器会画成 ^X，屏幕上的字数对不上；对不上就不改，保持原样。
        guard !command.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }),
              span.middleWidths.count == command.count, span.cols > 0,
              span.startColumn < span.cols, span.endRow >= span.startRow,
              span.cursor.y > span.endRow else { return nil }

        // 命令从包装第一格起排要几行。
        var column = span.startColumn, rowsNeeded = 1
        for width in span.middleWidths {
            if column + width > span.cols {
                rowsNeeded += 1
                column = 0
            }
            column += width
        }
        let rowsUsed = span.endRow - span.startRow + 1
        let removed = rowsUsed - rowsNeeded
        guard removed >= 0 else { return nil }

        func moveTo(row: Int, column: Int) -> String { "\u{1B}[\(row + 1);\(column + 1)H" }
        var out = "\u{1B}7\u{1B}[0m"
        out += moveTo(row: span.startRow, column: span.startColumn) + "\u{1B}[K"
        for row in (span.startRow + 1)..<(span.startRow + rowsNeeded) {
            out += moveTo(row: row, column: 0) + "\u{1B}[2K"
        }
        if removed > 0 {
            out += moveTo(row: span.startRow + rowsNeeded, column: 0) + "\u{1B}[\(removed)M"
        }
        out += moveTo(row: span.startRow, column: span.startColumn) + command
        out += "\u{1B}8"
        if removed > 0 {
            out += moveTo(row: span.cursor.y - removed, column: span.cursor.x)
        }
        return Plan(bytes: Data(out.utf8), outputRow: span.startRow + rowsNeeded)
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

    /// 连上之后把还没打进去的命令打进去：先等远端的行编辑器起来（`TrackedRunInjectionGate`），再挂上改写回显
    /// （`TrackedRunEchoRewrite`），再打。等的中途断了就留着，下次连上再打。
    func injectPendingTrackedRun() {
        guard connectionState == .connected, var run = trackedRun, !run.injected else { return }
        run.injected = true
        trackedRun = run
        let generation = feedGeneration
        Task { [weak self] in
            await self?.waitForLineEditor(generation: generation)
            guard let self, self.trackedRun?.id == run.id else { return }
            guard self.feedGeneration == generation, self.connectionState == .connected else {
                self.trackedRun?.injected = false
                return
            }
            self.rewriteEcho(of: run)
            try? await self.injectInput(run.inputLine, appendEnter: true)
        }
    }

    private func waitForLineEditor(generation: Int) async {
        let started = ContinuousClock.now
        var lastBytes = shadow.totalFedBytes, lastChange = started
        let initialBytes = lastBytes
        while !Task.isCancelled, feedGeneration == generation, connectionState == .connected {
            let now = ContinuousClock.now
            let bytes = shadow.totalFedBytes
            if bytes != lastBytes {
                lastBytes = bytes
                lastChange = now
            }
            if TrackedRunInjectionGate.isReady(
                lineEditorReady: shadow.bracketedPasteMode || shadow.isCursorAtPrompt,
                sawOutput: bytes != initialBytes,
                quietFor: Self.seconds(now - lastChange),
                waited: Self.seconds(now - started)) { return }
            try? await Task.sleep(for: TrackedRunInjectionGate.pollInterval)
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// 开始标记一进影子就改写回显（在泵的线程上、标记之后的字节之前）。
    private func rewriteEcho(of run: TerminalTrackedRun) {
        let shadow = shadow, box = run.rewrittenStart, pump = outputPump
        let prefix = run.echoPrefix, suffix = run.echoSuffix, command = run.command
        pump.whenFed(run.startMarkerBytes) { @Sendable [weak pump] in
            guard let pump, let span = shadow.locateEcho(prefix: prefix, suffix: suffix),
                  let plan = TrackedRunEchoRewrite.plan(span: span, command: command) else { return }
            pump.route(plan.bytes)
            box.marker = shadow.markRow(plan.outputRow)
        }
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
        if let start = run.rewrittenStart.marker ?? run.startMarker {
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
