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
    /// 输出泵（两端共用，见 `TerminalOutputPump`）。每拍喂完后转给镜像与检查点。
    @ObservationIgnored let outputPump = TerminalOutputPump(pacing: .desktop)
    /// 键盘 / 粘贴 / 远端输入与尺寸变化发往后端的有序通道（两端共用，见 `TerminalInputChannel`）。
    @ObservationIgnored let inputChannel = TerminalInputChannel()
    var outputBuffer: TerminalOutputBuffer { outputPump.buffer }
    /// 单测换掉它，预算的走向才不取决于这台机器解析得多快。
    var flushPacing: TerminalFlushPacing {
        get { outputPump.pacing }
        set { outputPump.pacing = newValue }
    }
    /// 当前绑定的代次：`connect` / `detach` / `dispose` / `close` 都会递增，旧绑定的在途结果据此作废。
    var feedGeneration: Int { outputPump.generation }
    /// 正在回放接回的历史输出：屏蔽终端应答和副作用（见 `TerminalSession+HeldSession`）。
    @ObservationIgnored var isReplayingHeldOutput = false
    /// 持有 PTY 的后端才有。
    @ObservationIgnored var heldCheckpoints: TerminalHeldCheckpoints?

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
    /// 含 `idle` 的那条（远控把它推给接入的设备：程序空闲也说明前台是 Agent 而不是 shell）。
    var programReport: ProgramStatusRecord?
    @ObservationIgnored var programStatusTracker = ProgramStatusTracker()
    /// 单测替换「用户此刻在不在看」：测试宿主不一定是前台 app，`NSApp.isActive` 由不得测试。
    @ObservationIgnored var userLookingOverride: (@MainActor () -> Bool)?
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

    /// 画面：Ghostty 的视图与它的 host-managed IO（见 `GhosttyTerminalBridge`）。
    @ObservationIgnored private(set) lazy var ghostty = GhosttyTerminalBridge(owner: self)

    /// 影子终端（libghostty-vt）：和画面吃同一份字节，uTerm 要读的终端状态都从它读——程序状态、通知、命令跟踪标记、
    /// 读屏、是否在备用屏、光标、kitty 键盘标志。尺寸跟着 Ghostty 报来的网格走。
    @ObservationIgnored let shadow: ShadowTerminal

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
        // 回滚上限和 surface 用同一个函数算（`GhosttyTerminalConfig.base`）。初始尺寸就是还没量到网格时报给后端的那个。
        self.shadow = ShadowTerminal(cols: 120, rows: 30,
                                     options: TerminalScrollbackLimits(lines: TerminalSettings.read().scrollback).shadowOptions)
        super.init()
        _ = ghostty
        installShadowEventHandler()
        outputPump.terminalView = view
        outputPump.onFed = { [weak self] bytes in
            guard let self else { return }
            // 紧跟在 feed 之后：镜像拿到的字节顺序与 Mac 终端实际解析的顺序完全一致。
            self.mirrorTap.didFeed(bytes)
            self.heldCheckpoints?.noteFed(bytes.count)
            // 先影子（同步解析，事件随之到达）后画面：画面挂上时要按影子的状态对齐。
            self.shadow.feed(Data(bytes))
            self.ghostty.didFeedShadow(bytes)
            self.repositionPinnedGridIfCursorMoved()
        }
        TerminalTheme.apply(to: terminalView, settings: TerminalSettings.read(), dark: true)
        terminalView.terminalDelegate = self
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
    static func makeContextMenu(for terminalView: NSView) -> NSMenu {
        let menu = NSMenu()
        let copyItem = NSMenuItem(title: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
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
        shadow.setEventHandler(nil)
        ghostty.dispose()
    }

    /// 起后端时用的行列数：Ghostty 报过网格就用它，还没报过（视图没进过窗口）用影子终端的初始尺寸。
    var currentProcessSize: (cols: UInt16, rows: UInt16) {
        inputChannel.latestSize ?? (cols: 120, rows: 30)
    }

    /// 后端来了一批输出（测试直接喂字节用；正式路径由输出泵按节拍调同一条链）。
    func receiveOutputForTesting(_ data: Data) {
        let bytes = ArraySlice([UInt8](data))
        terminalView.feed(byteArray: bytes)
        outputPump.onFed?(bytes)
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
        // 建连期间的键入照样排进这条后端（与改前一样）；尺寸等连上之后再补发。
        inputChannel.bind(to: backend, sendingLatestSize: false)
        connectionState = .connecting
        do {
            try await backend.connect()
        } catch {
            // Superseded while suspended — a newer connect/dispose owns the
            // session now; don't overwrite its state or clear its backend.
            guard feedGeneration == myGen else { return }
            connectionState = .failed("\(error)")
            self.backend = nil
            inputChannel.unbind()
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
            ghostty.resync()
        }
        connectionState = .connected
        // 注册到看门狗：系统唤醒 / 网络恢复后主动探测，半死连接不再顶着
        // 「已连接」徽标静默挂着。弱引用注册，幂等。
        ConnectionWatchdog.shared.register(self)
        inputChannel.sendLatestSizeNow()
        outputPump.start(backend.outputStream)
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
        inputChannel.sendLatestSizeNow()

        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            self?.inputChannel.sendLatestSizeNow()
        }
    }

    /// Clears the visible terminal and scrollback without detaching from the
    /// backend, so new output continues to stream into the same view.
    func clearOutput() {
        outputBuffer.clear()
        let bytes = Array("\u{1B}[3J\u{1B}[H\u{1B}[2J".utf8)
        terminalView.feed(byteArray: ArraySlice(bytes))
        shadow.feed(Data(bytes))
        // 这几个字节不走输出流，镜像那边改发一份快照对齐。
        mirrorTap.invalidateAll()
        heldCheckpoints?.noteScreenChanged()
        ghostty.resync()
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
        outputPump.reset()
        inputChannel.unbind()
        exitObserverTask?.cancel()
        exitObserverTask = nil
        heldCheckpoints?.cancel()
        heldCheckpoints = nil
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
    /// 读的是影子终端的活动屏（含回滚）的末尾，不是用户滚到的位置：用户往上滚过之后，要的仍然是「最近的输出」。
    /// 末尾的空行先跳过再往上取（`clear` 之后、全屏程序退出还原主屏之后，末尾可以挂着几百行空行），一行终端一段文字。
    func snapshotScreen(
        lines: Int = ControlProtocol.defaultScreenLines,
        maxBytes: Int = ControlProtocol.maxScreenBytes
    ) -> TerminalScreenReader.Result {
        guard lines > 0 else { return TerminalScreenReader.Result(lines: [], truncated: false) }
        let recent = shadow.recentLines(lines)
        var result = TerminalScreenReader.trim(lines: recent.lines, maxLines: lines, maxBytes: maxBytes)
        // 起点被 `lines` 卡住 → 上面还有历史没读出来，如实标截断。
        if recent.truncated { result.truncated = true }
        return result
    }

    /// 往这条会话的 PTY 写文本 —— 与用户键入走**完全相同**的通道
    /// （`backend.write` → `SSHConnection.write` → `state.enqueue(.write)`）。
    ///
    /// 因此：注入与用户键入会交错、**没有输出边界**，不保证调用方能拿到这条命令的结果。
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
