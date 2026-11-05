import SwiftUI
import SwiftTerm
import AppKit

/// Owns one `SwiftTerm.TerminalView` for the lifetime of its enclosing
/// terminal pane. The view is *not* recreated when the SwiftUI pane is
/// rebuilt (e.g. on maximize / restore), so the scrollback buffer survives
/// those layout changes. Acts as the view's delegate so user input / resize
/// are forwarded to the bound backend without needing a separate coordinator.
@MainActor
@Observable
final class TerminalSession: NSObject, TerminalViewDelegate {
    let terminalView: SwiftTerm.TerminalView
    private(set) var backend: (any TerminalBackend)?
    private var feedTask: Task<Void, Never>?
    @ObservationIgnored let outputBuffer = TerminalOutputBuffer(capacityBytes: 4 * 1024 * 1024)
    /// 单测换掉它，预算的走向才不取决于这台机器解析得多快。
    @ObservationIgnored var flushPacing = TerminalFlushPacing.desktop
    @ObservationIgnored private var outputFlushTask: Task<Void, Never>?
    private(set) var feedGeneration: Int = 0
    /// 正在回放接回的历史输出：屏蔽终端应答和副作用（见 `TerminalSession+HeldSession`）。
    @ObservationIgnored var isReplayingHeldOutput = false
    /// 持有 PTY 的后端才有。
    @ObservationIgnored var heldCheckpoints: TerminalHeldCheckpoints?

    // Resize forwarding state. `TerminalContainerView` commits a new size only
    // once the pane has stopped changing, so a splitter drag produces one
    // `sizeChanged`, forwarded to the backend right away.
    // `lastForwardedResize` dedupes "same dimensions" reports.
    @ObservationIgnored var latestReportedResize: (cols: UInt16, rows: UInt16)?
    @ObservationIgnored var lastForwardedResize: (cols: UInt16, rows: UInt16)?
    @ObservationIgnored var pendingResize: (cols: UInt16, rows: UInt16)?
    @ObservationIgnored var resizeFlushTask: Task<Void, Never>?

    /// 终端连接状态。`connect(using:)` 推进；远端结束置 `disconnected`。
    typealias ConnectionState = TerminalConnectionState
    private(set) var connectionState: ConnectionState = .idle {
        didSet {
            guard connectionState != oldValue else { return }
            // 标题说的是那条连接上正在跑的程序，连接没了就不再成立。
            if connectionState != .connected {
                shellTitle = nil
                resetProgramStatus()
                resetTrueColorOffer()
            }
            onConnectionStateChange?(connectionState)
        }
    }

    /// shell 或程序用 OSC 0 / 2 设的标题；没设过、设成空、连接已断开时为 nil。
    /// 程序可能高频刷新它（Claude Code 的转圈动画），所以标签要在单枚标签自己的 body 里读，
    /// 别让整条标签条或整个窗口挂在它上面。
    private(set) var shellTitle: String?

    /// 程序用 OSC 7501 报告的状态里最需要人处理的那条；没有或空闲时为 nil。
    /// 和 `shellTitle` 一样，要在单枚标签自己的 body 里读。
    var programStatus: ProgramStatusRecord?
    @ObservationIgnored var programStatusBoard = ProgramStatusBoard()
    /// 窗格上的真彩提示，见 `TerminalSession+TrueColor`。
    var trueColorOffer: TrueColorOffer?
    @ObservationIgnored var trueColorChecked = false
    /// 程序需要用户注意时调用。默认发系统通知，单测里换掉。
    @ObservationIgnored var attentionSink: (@MainActor (TerminalAttention) -> Void)?

    /// 连接状态变化的接线钩子。`PaneModel` 用它把「远端退出 / 重连成功」同步给
    /// 跨窗口注册表 —— 否则断开的会话仍被 `terminals` 列成活的，
    /// `terminal-read` 会一直回同一张冻结的画面。
    ///
    /// `@ObservationIgnored`：是接线不是状态，改它不该让任何视图失效。
    @ObservationIgnored var onConnectionStateChange: (@MainActor (ConnectionState) -> Void)?

    @ObservationIgnored private var exitObserverTask: Task<Void, Never>?

    /// 命令行 `terminal open -- cmd` 在这条会话里跑的那条命令（见 `TerminalSession+TrackedRun`）。
    /// 一条会话同一时刻只跟踪一条；新的覆盖旧的。
    @ObservationIgnored var trackedRun: TerminalTrackedRun?

    /// 远控镜像：把这条会话的字节流转给接入的设备（见 `TerminalMirrorTap`）。
    @ObservationIgnored let mirrorTap: TerminalMirrorTap

    /// 正在接管这条会话尺寸的远端设备名；nil = 没有。窗格据此显示「正在被接管」的指示条。
    var remoteController: String?

    /// 在 Mac 上断开远端接管（窗格指示条上的「断开」）。由远控连接在接入时装上。
    @ObservationIgnored var remoteDisconnect: (@MainActor () -> Void)?

    override init() {
        // Give SwiftTerm a non-trivial initial frame so its first `setFrameSize`
        // pass computes a meaningful `cellDimension` + initial cols/rows. With
        // `frame: .zero`, the very first layout has cellDimension nil → cols
        // stays at the default 80, and any PTY output that arrives before the
        // real SwiftUI-driven layout pass gets wrapped + frozen in scrollback
        // at 80 columns. Result: visible "dead zone" on the right side of the
        // pane until users scroll to brand-new output. 1280×800 ≈ a typical
        // pane size; SwiftUI overrides this on mount anyway, we only need a
        // sane initial so cellDimension is valid when the first frame arrives.
        let view = CopyableTerminalView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
        view.preservesSelectionDuringOutput = true
        self.terminalView = view
        self.mirrorTap = TerminalMirrorTap { [unowned view] in view.getTerminal() }
        super.init()
        TerminalTheme.apply(to: terminalView, settings: TerminalSettings.read(), dark: true)
        terminalView.terminalDelegate = self
        terminalView.menu = Self.makeContextMenu(for: terminalView)
        installTrackedRunMarkers()
        installProgramStatusHandlers()
        view.onFocusGained = { [weak self] in self?.acknowledgeProgramStatus() }
        view.onPasteImage = { [weak self] in self?.pasteImage($0) ?? false }
        view.onControlVImage = { [weak self] in self?.handleControlVImage($0) ?? false }
        attentionSink = { [weak self] attention in
            guard let self else { return }
            TerminalAttentionCenter.shared.post(attention, from: self)
        }
    }

    func receiveShellTitle(_ title: String) {
        let next = TerminalTitle.normalize(title)
        guard next != shellTitle else { return }
        shellTitle = next
    }

    /// Right-click context menu for the live terminal. SwiftTerm's
    /// `TerminalView` implements `copy:`, `paste:`, and `selectAll:` (plus
    /// `validateUserInterfaceItem` to enable/disable them) but ships no context
    /// menu — `Cmd+C` was the only copy affordance. Items target the terminal
    /// view directly so a right-click acts on this pane's selection regardless
    /// of which view currently holds first responder.
    private static func makeContextMenu(for terminalView: SwiftTerm.TerminalView) -> NSMenu {
        let menu = NSMenu()
        let copyItem = NSMenuItem(title: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        let pasteItem = NSMenuItem(title: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let selectAllItem = NSMenuItem(title: "全选", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")
        for item in [copyItem, pasteItem, selectAllItem] {
            item.target = terminalView
        }
        menu.addItem(copyItem)
        menu.addItem(pasteItem)
        menu.addItem(.separator())
        menu.addItem(selectAllItem)
        return menu
    }

    /// Call before letting ARC release this session. Severs the SwiftTerm
    /// delegate link (which is unowned-unsafe), cancels in-flight tasks, and
    /// prevents post-dealloc callbacks → objc_release crashes. Must run on
    /// the MainActor (the type is @MainActor so this is enforced by Swift).
    func dispose() {
        resetFeedAndResizeState()
        terminalView.terminalDelegate = nil
        backend = nil
    }

    var currentProcessSize: (cols: UInt16, rows: UInt16) {
        latestReportedResize ?? (cols: 120, rows: 30)
    }

    /// 用给定后端建立连接：connect() 成功则绑定并开始泵送输出，
    /// 失败置 failed，远端结束置 disconnected。
    func connect(using backend: any TerminalBackend) async {
        resetFeedAndResizeState()
        // `resetFeedAndResizeState()` just bumped `feedGeneration`; snapshot it
        // as this call's identity token. `backend.connect()` below suspends and
        // frees the MainActor — a second `connect(using:)`, `dispose()`, or
        // `detach()` can run during that gap and bump `feedGeneration` again.
        // When this call resumes it must not clobber the newer binding's state.
        let myGen = feedGeneration
        self.backend = backend
        connectionState = .connecting
        do {
            try await backend.connect()
        } catch {
            // Superseded while suspended — a newer connect/dispose owns the
            // session now; don't overwrite its state or clear its backend.
            guard feedGeneration == myGen else { return }
            connectionState = .failed("\(error)")
            self.backend = nil
            return
        }
        // Superseded check: bail unless this is still the live binding. The
        // `===` identity guard rejects the case where a newer connect bound a
        // different backend at the same generation boundary.
        guard feedGeneration == myGen, self.backend === backend else { return }
        // 在翻成「已连接」之前恢复画面：手机一接入拿到的快照就是完整的。
        if let held = backend as? any HeldTerminalBackend {
            guard await restoreHeldScreen(from: held, generation: myGen),
                  feedGeneration == myGen, self.backend === backend else { return }
        }
        connectionState = .connected
        // 注册到看门狗：系统唤醒 / 网络恢复后主动探测，半死连接不再顶着
        // 「已连接」徽标静默挂着。弱引用注册，幂等。
        ConnectionWatchdog.shared.register(self)
        if let latestReportedResize {
            forwardResizeImmediately(latestReportedResize)
        }
        startFeedLoop()
        startOutputFlushLoop()
        observeExit(of: backend, generation: myGen)
        injectPendingTrackedRun()
    }

    private func observeExit(of backend: any TerminalBackend, generation: Int) {
        exitObserverTask?.cancel()
        exitObserverTask = Task { [weak self] in
            for await _ in backend.exitStream {
                await MainActor.run { [weak self] in
                    // Guard on the generation token, not just the enum value:
                    // an exit event from an old backend could otherwise flip a
                    // healthy newer session to `.disconnected`.
                    guard let self, self.feedGeneration == generation else { return }
                    if self.connectionState == .connected {
                        self.connectionState = .disconnected
                    }
                }
            }
        }
    }

    func refreshTerminalSizeSoon() {
        terminalView.needsLayout = true
        terminalView.layoutSubtreeIfNeeded()
        if let latestReportedResize {
            forwardResizeImmediately(latestReportedResize)
        }

        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard let self else { return }
            self.terminalView.needsLayout = true
            self.terminalView.layoutSubtreeIfNeeded()
            if let latestReportedResize = self.latestReportedResize {
                self.forwardResizeImmediately(latestReportedResize)
            }
        }
    }

    /// Clears the visible terminal and scrollback without detaching from the
    /// backend, so new output continues to stream into the same view.
    func clearOutput() {
        outputBuffer.clear()
        let bytes = Array("\u{1B}[3J\u{1B}[H\u{1B}[2J".utf8)
        terminalView.feed(byteArray: ArraySlice(bytes))
        // 这几个字节不走输出流，镜像那边改发一份快照对齐。
        mirrorTap.invalidateAll()
        heldCheckpoints?.noteScreenChanged()
    }

    func detach() {
        resetFeedAndResizeState()
        backend = nil
    }

    /// 在尚未取得后端时（如认证解析失败）直接置失败态。
    func markFailed(_ message: String) {
        connectionState = .failed(message)
    }

    /// 关闭当前后端并复位。切换服务器前调用。
    func close() async {
        if let backend { await backend.close() }
        resetFeedAndResizeState()
        backend = nil
        connectionState = .idle
    }

    /// Bump the feed generation and tear down every in-flight feed/flush/resize
    /// task and buffer, so stale output from a previous binding is rejected by
    /// both the ingress task and the flush loop. The generation bump must come
    /// first for that rejection to be reliable.
    private func resetFeedAndResizeState() {
        feedGeneration &+= 1
        feedTask?.cancel()
        feedTask = nil
        outputFlushTask?.cancel()
        outputFlushTask = nil
        outputBuffer.clear()
        pendingResize = nil
        resizeFlushTask?.cancel()
        resizeFlushTask = nil
        lastForwardedResize = nil
        exitObserverTask?.cancel()
        exitObserverTask = nil
        heldCheckpoints?.cancel()
        heldCheckpoints = nil
        // 换了一条连接，上一个程序设的光标不该留下来：下次 SwiftUI 更新时重装。
        (terminalView as? CopyableTerminalView)?.appliedLook = nil
    }

    private func startFeedLoop() {
        guard let backend else { return }
        let myGen = feedGeneration
        let buffer = outputBuffer

        // Iterate on a detached task so it isn't gated by MainActor work
        // (SwiftUI rendering, other panes' feed loops). Chunks are staged in a
        // bounded buffer and a MainActor flusher feeds SwiftTerm on a frame-like
        // cadence instead of hopping to MainActor for every output batch.
        feedTask = Task.detached(priority: .userInitiated) {
            let stream = backend.outputStream
            for await chunk in stream {
                if Task.isCancelled { break }
                buffer.append(chunk, generation: myGen)
            }
        }
    }

    private func startOutputFlushLoop() {
        outputFlushTask?.cancel()
        let myGen = feedGeneration
        let buffer = outputBuffer
        outputFlushTask = Task { [weak self] in
            var pacer = TerminalFlushPacer(pacing: self?.flushPacing ?? .desktop)
            while !Task.isCancelled {
                guard let self else { return }
                guard self.feedGeneration == myGen else { return }
                pacer.use(self.flushPacing)

                if let delayMs = self.flushPendingOutput(generation: myGen, pacer: &pacer) {
                    // 活跃路径：让短时间内陆续到达的字节合批一次性 feed。
                    try? await Task.sleep(for: .milliseconds(delayMs))
                } else {
                    // 空闲路径：挂起到下一次 append（或 clear 唤醒，让被取消的
                    // generation 通过下一轮顶部的 guard 退出）。这条路径取代了
                    // 旧的 100ms 轮询 —— 那 100ms 是 echo 字符在终端中可见前
                    // 的最坏延迟，是"输入不跟手"的根因。
                    await buffer.waitForData()
                }
            }
        }
    }

    /// 无条件 feed —— 后台（非活动）标签也在全速解析 VT，这是**有意保留**的。
    ///
    /// 2026-09-01 量过它的成本结构，别再凭「批量化能省」的直觉来改这里。
    /// 测法：同进程内交替翻转块大小做配对测量（这台机器 load 在 4–14 乱跳，
    /// 跨进程不可比），6 个 `TerminalView` 交错喂同一份 `script(1)` 录的真实
    /// 语料（带色 git log/ls -laR + vim 进出 alternate screen + top 全屏重绘），
    /// 每轮正逆序交替、7 轮取中位数，Release 构建。
    ///
    ///   每次 feed 的块大小    调用次数    6.57 MB 总耗时
    ///   64 B                 107 719     176.8 ms
    ///   433 B（线上实测均值）  15 922      157.4 ms
    ///   32 KB                211         153.3 ms
    ///   256 KB               27          153.9 ms
    ///
    /// 拟合出来：**每次调用的固定开销只有 0.21 µs，按字节的解析是 23.3 ms/MB**
    /// （随内容在 9–27 ms/MB 之间浮动）。也就是说线上那 433 B 的包里，固定开销
    /// 只占 feed 总耗时的 2.6%；把 flush 从 433 B 攒到 32 KB 就只能省这 2.6%，
    /// 连 64 B → 256 KB 的极端全跨度也只有 13%。批量化在这里省不到 CPU。预算放大
    /// （`TerminalFlushPacing`）要解决的是积压时的吞吐，不是省 CPU；没有积压时每拍
    /// 只有几百字节，预算多大都一样，也就不影响 echo 延迟。
    ///
    /// 绝对量级也不值得动：6 个后台标签合计 142 KB/s 的输出，在 Release 下
    /// ≈ 3.3 ms/s 主线程时间（0.3% 单核）。`uAppKit/docs/pane-groups-design.md`
    /// §6-2 记的 31.5–65 ms/s 是 **Debug** 构建（`-Onone`）量的，不代表发布版：
    /// 同一份语料同一套测法，Debug 224.8 ms/MB vs Release 23.9 ms/MB，差 9.4×。
    ///
    /// 再往下就只剩「后台标签先不解析、切回来再补」。它省不到 CPU（字节一个不少
    /// 还是要解析，只是挪到切回来的那一刻，反而制造一次卡顿），却必然改变行为：
    /// 补 feed 之前若发生过 resize，积压字节会按新 cols 重排，切回来的内容与不
    /// 优化时不再逐字相同。为 3.3 ms/s 付这个代价不划算。
    ///
    /// 顺带钉住一条：SwiftTerm 的解析器对分块边界是中立的 —— 上面五种块大小
    /// 喂完同一份语料后，主屏/alt 屏全文、逐格字符与属性、scrollback、光标位置
    /// 全部逐字相同（实测比对过指纹）。所以将来真要改批量策略，正确性这一侧
    /// 是安全的，不安全的只有上面那条「延迟到可见时再补」。
    ///
    /// 返回下一拍前要等的毫秒数；nil 表示没有可喂的字节。
    private func flushPendingOutput(generation: Int, pacer: inout TerminalFlushPacer) -> Int? {
        guard feedGeneration == generation else { return nil }
        let chunk = outputBuffer.drain(maxBytes: pacer.budget, generation: generation)
        guard !chunk.isEmpty else { return nil }

        let bytes = ArraySlice([UInt8](chunk))
        let backlogged = pacer.isBacklogged(fed: bytes.count, hasMore: outputBuffer.hasBufferedBytes)
        let start = CFAbsoluteTimeGetCurrent()
        terminalView.feedPaced(bytes, backlogged: backlogged)
        let end = CFAbsoluteTimeGetCurrent()
        // 紧跟在 feed 之后：镜像拿到的字节顺序与 Mac 终端实际解析的顺序完全一致。
        mirrorTap.didFeed(bytes)
        heldCheckpoints?.noteFed(bytes.count)
        return pacer.didFeed(bytes: bytes.count, elapsedMs: (end - start) * 1000,
                             backlogged: backlogged, nowMs: end * 1000)
    }

}

// MARK: - 读屏与注入（CLI `terminal-read` / `terminal-send`，Agent 的 read_terminal 也走这里）

/// `injectInput` 的失败分类。协议层把它翻成 `terminal_disconnected`。
nonisolated enum TerminalInjectionError: Error, Equatable {
    /// 会话没有后端，或后端已断开 —— 注入无处可去。
    case disconnected
}

extension TerminalSession {

    /// 抓「最近 `lines` 行」的**快照**（不是流）：既含当前可见屏幕，也兜住刚滚走的输出。
    ///
    /// 必须在 MainActor 上跑（`terminalView` 是 NSView，缓冲区随渲染线程更新）——
    /// 类型本身 `@MainActor`，由编译器保证。
    ///
    /// - Note: SwiftTerm 只把 `getScrollInvariantLine(row:)`（越界回 nil）、
    ///   `buffer.totalLinesTrimmed`、`getTopVisibleRow()`、`rows` 开放出来；
    ///   `buffer.lines` 与 `buffer.linesTop` 都是 **internal**，包外拿不到「缓冲区共几行」。
    ///   所以末行靠越界二分反推（见 `scrollInvariantEndRow`）。**不要**为此去改
    ///   `vendor/SwiftTerm` —— 那是带补丁清单的 vendored 副本，补丁越少越好。
    func snapshotScreen(
        lines: Int = ControlProtocol.defaultScreenLines,
        maxBytes: Int = ControlProtocol.maxScreenBytes
    ) -> TerminalScreenReader.Result {
        guard lines > 0, let terminal = terminalView.terminal else {
            return TerminalScreenReader.Result(lines: [], truncated: false)
        }
        let top = terminal.buffer.totalLinesTrimmed  // == buffer.linesTop
        let end = scrollInvariantEndRow(terminal)    // 排他上界
        guard end > top else { return TerminalScreenReader.Result(lines: [], truncated: false) }

        // **先向前跳过尾部空行，再往上取 `lines` 行。**
        //
        // 不要退回「多取一屏」（`end - (lines + rows)`）那种写法：空白尾巴不止一屏 ——
        // `clear` 之后、TUI（vim / less）退出还原主屏之后、或者刚 `Ctrl-L` 过，缓冲区
        // 末尾可以挂着几百行空行。而 `TerminalScreenReader.trim` 会把**全部**尾随空行
        // 去掉，于是多取的那一屏被裁光，读屏返回空 —— 屏幕上明明有内容。
        var lastNonEmpty = end - 1
        while lastNonEmpty >= top, isBlankRow(terminal, lastNonEmpty) { lastNonEmpty -= 1 }
        guard lastNonEmpty >= top else {
            return TerminalScreenReader.Result(lines: [], truncated: false)
        }

        let start = max(top, lastNonEmpty + 1 - lines)
        var raw: [String] = []
        raw.reserveCapacity(lastNonEmpty - start + 1)
        for row in start...lastNonEmpty {
            guard let line = terminal.getScrollInvariantLine(row: row) else { continue }
            raw.append(line.translateToString(trimRight: true))
        }

        var result = TerminalScreenReader.trim(lines: raw, maxLines: lines, maxBytes: maxBytes)
        // 起点被 `lines` 卡住 → 上面还有历史没读出来，如实标截断。
        if start > top { result.truncated = true }
        return result
    }

    /// 这一行在 `TerminalScreenReader.trim` 眼里算不算空行。
    ///
    /// 判定必须与 `trim` **逐字一致**（它按 `String.isEmpty` 去尾），否则要么跳不干净
    /// （读屏又被 trim 掏空），要么跳过头（把有内容的行当空的丢掉）。所以最终裁决权
    /// 交给和取行时同一个 `translateToString(trimRight:)`；`getTrimmedLength() == 0`
    /// 只是它的快速路径 —— 整行都是空 cell（`code == 0`）时不必分配字符串。
    ///
    /// 注意 `trimRight` 只去空 cell、**不去字面空格**：一行 8 个空格译出来是
    /// `"        "`，非空，按「有内容」算。实测如此，别按直觉改。
    private func isBlankRow(_ terminal: SwiftTerm.Terminal, _ row: Int) -> Bool {
        guard let line = terminal.getScrollInvariantLine(row: row) else { return true }
        if line.getTrimmedLength() == 0 { return true }
        return line.translateToString(trimRight: true).isEmpty
    }

    /// 反推 scroll-invariant 行号的**排他上界**（= `buffer.linesTop + buffer.lines.count`）。
    ///
    /// `buffer.lines` 与 `buffer.linesTop` 都是 internal，包外拿不到行数，只能靠
    /// `getScrollInvariantLine(row:)` 越界回 nil 来二分。上界不用探 ——
    /// `buffer.getCorrectBufferLength(rows)`（public，`Buffer.swift` ~654）就是那条
    /// `CircularBufferLineList` 的 `maxLength`（`rows + scrollback`），行数**永远**
    /// 不超过它，所以 `linesTop + capacity` 必然越界，直接拿它当二分的右端。
    ///
    /// 为什么不能只用可见屏（`getTopVisibleRow() + rows`）：用户往上滚过之后，
    /// 可见屏的底部不再是缓冲区末行，那样会读到「用户正在看的地方」而不是「最近的输出」。
    func scrollInvariantEndRow(_ terminal: SwiftTerm.Terminal) -> Int {
        let top = terminal.buffer.totalLinesTrimmed
        guard terminal.getScrollInvariantLine(row: top) != nil else { return top }
        let capacity = max(terminal.buffer.getCorrectBufferLength(terminal.rows), 1)
        var known = top                              // 已知合法
        var unknown = top + capacity                 // 必然越界（见上）
        // 上游若哪天把 `getScrollInvariantLine` 改成 clamp（越界不再回 nil），
        // 这个不变量就没了；Debug 下当场炸出来，Release 下二分仍会收敛到
        // `top + capacity`（不会死循环），只是读到的末行偏大。
        assert(terminal.getScrollInvariantLine(row: unknown) == nil,
               "getScrollInvariantLine 不再对越界行返回 nil —— 末行反推失效")
        while unknown - known > 1 {
            let mid = known + (unknown - known) / 2
            if terminal.getScrollInvariantLine(row: mid) != nil {
                known = mid
            } else {
                unknown = mid
            }
        }
        return known + 1
    }

    /// 往这条会话的 PTY 写文本 —— 与用户键入走**完全相同**的通道
    /// （`backend.write` → `SSHConnection.write` → `state.enqueue(.write)`）。
    ///
    /// 因此：注入与用户键入会交错、**没有输出边界**（uTerm 与 vendored SwiftTerm 都
    /// 没有 OSC 133 shell-integration 标记），不保证调用方能拿到这条命令的结果。
    /// 要结果请走 `run`；`terminal-send` 的正当用途是「让用户看见」。
    ///
    /// - Parameter appendEnter: 追加 `\r`（回车）执行。
    /// - Throws: `TerminalInjectionError.disconnected` —— 没有后端或状态不是 `.connected`。
    func injectInput(_ text: String, appendEnter: Bool = false) async throws {
        guard connectionState == .connected, let backend else {
            throw TerminalInjectionError.disconnected
        }
        let payload = appendEnter ? text + "\r" : text
        await backend.write(Data(payload.utf8))
    }
}

// MARK: - 连接健康探测（ConnectionWatchdog）

extension TerminalSession: ConnectionHealthProbing {
    /// 系统唤醒 / 网络恢复后由 `ConnectionWatchdog` 调用。只在自认「已连接」时
    /// 探测；后端判死时会自行强制关闭通道，`exitStream` 级联把状态翻到
    /// `.disconnected`（窗格盖上「连接已断开 / 重新连接」），这里不写任何状态。
    func probeConnectionHealth() async {
        await connectionState.probeHealth(of: backend)
    }
}
