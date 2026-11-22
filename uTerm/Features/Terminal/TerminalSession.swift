import SwiftUI
import AppKit
import GhosttyTerminal
import os

/// 一条终端会话：Ghostty 的画面（`ghostty`）+ 影子终端（`shadow`）+ 后端。窗格的 SwiftUI 视图重建（最大化 / 还原、
/// 切标签）时会话不重建，画面与回滚随之保留。键盘输入、终端应答、网格尺寸从 Ghostty 来，经有序输入通道发往后端。
@MainActor
@Observable
final class TerminalSession: NSObject {
    private(set) var backend: (any TerminalBackend)?
    /// 影子 + surface 的接线（两端共用，见 `TerminalSurfaceLink`）。下面的 `shadow` / `surfaceIO` / `outputPump` 就是它的。
    @ObservationIgnored let link: TerminalSurfaceLink
    /// 影子终端（libghostty-vt）：和画面吃同一份字节，uTerm 要读的终端状态都从它读——程序状态、通知、命令跟踪标记、
    /// 读屏、是否在备用屏、光标、kitty 键盘标志、镜像与检查点的快照。尺寸跟着 Ghostty 报来的网格走。
    @ObservationIgnored let shadow: ShadowTerminal
    /// Ghostty 的 host-managed IO：输出从这里进 surface，键盘输入与应答从它的回调出来。
    @ObservationIgnored let surfaceIO: InMemoryTerminalSession
    /// 输出泵（两端共用，见 `TerminalOutputPump`）：后端输出 → 影子终端 → tap（镜像、检查点）→ surface。
    @ObservationIgnored let outputPump: TerminalOutputPump
    /// 画面：Ghostty 的视图（见 `GhosttyTerminalBridge`）。surface 等视图第一次进窗口才建。
    @ObservationIgnored private(set) lazy var ghostty = GhosttyTerminalBridge(owner: self)
    /// 键盘 / 粘贴 / 远端输入与尺寸变化发往后端的有序通道（两端共用，见 `TerminalInputChannel`）。
    @ObservationIgnored let inputChannel = TerminalInputChannel()
    /// 当前绑定的代次：`connect` / `detach` / `dispose` / `close` 都会递增，旧绑定的在途结果据此作废。
    var feedGeneration: Int { outputPump.generation }
    /// 输出泵的 tap 要用、又得在主线程上换的那几样（检查点、钉尺寸时的跟光标）。
    @ObservationIgnored private let feedTaps = TerminalFeedTaps()
    /// 持有 PTY 的后端才有。
    var heldCheckpoints: TerminalHeldCheckpoints? {
        get { feedTaps.checkpoints }
        set { feedTaps.checkpoints = newValue }
    }

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
    /// 影子终端事件的处理（程序状态、查询应答、历史、远控镜像的规则两端共用，见 `TerminalEventRouter`）。
    var events: TerminalEventRouter { link.events }
    var programStatusTracker: ProgramStatusTracker { events.tracker }
    /// 程序状态的记账副本，和字节位置严格对应，存进 holder 检查点（见 `ProgramStatusJournal`）。
    var statusJournal: ProgramStatusJournal { events.journal }
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

    override init() {
        // 回滚上限和 surface 用同一个函数算（`GhosttyTerminalConfig.base`）。初始尺寸就是还没量到网格时报给后端的那个。
        let settings = TerminalSettings.read()
        let link = TerminalSurfaceLink(cols: 120, rows: 30,
                                       options: TerminalScrollbackLimits(lines: settings.scrollback)
                                           .shadowOptions(cursorBlink: settings.cursorBlink))
        self.link = link
        let shadow = link.shadow, pump = link.pump
        self.shadow = shadow
        surfaceIO = link.io
        outputPump = pump
        mirrorTap = TerminalMirrorTap(snapshot: { try? shadow.untrimmedSnapshot(scrollbackLines: RemoteConstants.snapshotScrollback) },
                                      exclusively: { pump.performWhileFeedingPaused($0) })
        super.init()
        // tap：影子刚解析完这一片、泵的锁还在手上。镜像与检查点拿到的字节顺序与终端实际解析的顺序完全一致。
        // 弱引用：镜像 tap 借泵的锁（`exclusively` 强持着泵），这里再强持 tap 就成了环，关掉标签后泵、影子、surface IO 都放不掉。
        pump.onFed = { [weak mirrorTap, weak feedTaps] bytes in
            mirrorTap?.didFeed(bytes)
            feedTaps?.didFeed(bytes.count)
        }
        feedTaps.onPinnedFeed = { [weak self] in self?.repositionPinnedGridIfCursorMoved() }
        _ = ghostty
        installShadowEventHandler()
        installShadowClipboardHandler()
        // 未知 OSC 只要命令跟踪的起止标记（`TerminalTrackedRun`）。
        shadow.reportUnknownOSC(withPrefixes: ["\(TerminalTrackedRun.oscCode);"])
        // surface 没在吃字节的时候（还没建、被丢弃），查询由影子终端答；应答和键盘输入走同一条通道。
        link.onShadowReply = { [weak self] in self?.sendHostBytes($0) }
        updateShadowColors(dark: NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        attentionSink = { [weak self] attention in
            guard let self else { return }
            TerminalAttentionCenter.shared.post(attention, from: self)
        }
    }

    /// 影子终端替 surface 答颜色查询（OSC 10 / 11 / 12、`CSI ? 996 n`）时用的配色，跟着 app 外观走。
    /// 只在 surface 不吃字节时（还没建）才轮到影子答；`GhosttyHostView` 每次更新都会调，值没变就不动。
    func updateShadowColors(dark: Bool) {
        link.syncShadowColors(dark: dark)
    }

    /// uTerm 自己要发给程序的字节（OSC 7501 应答、贴图后的路径），以及 Ghostty 发出的键盘输入与终端应答。
    /// 进有序输入通道（`TerminalInputChannel`），按产生顺序到达后端。接回时回放的历史不会走到这里（影子喂历史时不应答，
    /// 见 `ShadowTerminal.feed(_:asHistory:)`），所以回放期间用户的按键照常发出。
    func sendHostBytes(_ data: Data) {
        inputChannel.write(data)
    }

    /// 钉住尺寸（远控接管）期间，每批输出之后要看一眼光标换行没有。
    var tracksCursorForPinnedGrid: Bool {
        get { feedTaps.notifiesPinnedFeed }
        set { feedTaps.notifiesPinnedFeed = newValue }
    }

    func receiveShellTitle(_ title: String) {
        let next = TerminalTitle.normalize(title)
        guard next != shellTitle else { return }
        shellTitle = next
    }

    /// 终端的右键菜单：拷贝 / 粘贴 / 全选。菜单项的 target 直接是终端视图，右键作用在这个窗格的选区上，
    /// 不管此刻第一响应者是谁。
    static func makeContextMenu(for terminalView: NSView) -> NSMenu {
        let menu = NSMenu()
        let copyItem = NSMenuItem(title: String(localized: "拷贝"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        let pasteItem = NSMenuItem(title: String(localized: "粘贴"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let selectAllItem = NSMenuItem(title: String(localized: "全选"), action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")
        for item in [copyItem, pasteItem, selectAllItem] {
            item.target = terminalView
        }
        menu.addItem(copyItem)
        menu.addItem(pasteItem)
        menu.addItem(.separator())
        menu.addItem(selectAllItem)
        return menu
    }

    /// 放掉这条会话之前调：停掉在途的任务、断开影子终端与画面的回调。
    func dispose() {
        resetFeedAndResizeState()
        backend = nil
        shadow.setEventHandler(nil)
        shadow.setReplyHandler(nil)
        ghostty.dispose()
    }

    /// 起后端时用的行列数：Ghostty 报过网格就用它，还没报过（视图没进过窗口）用影子终端的初始尺寸。
    var currentProcessSize: (cols: UInt16, rows: UInt16) {
        inputChannel.latestSize ?? (cols: 120, rows: 30)
    }

    /// 后端来了一批输出（测试直接喂字节用）：和正式路径同一条链（影子 → tap → surface），只是不经入站任务与闸门，
    /// 返回时影子终端已经解析完、事件已经处理完。
    func receiveOutputForTesting(_ data: Data) {
        outputPump.route(data)
    }

    /// 用给定后端建立连接：connect() 成功则绑定并开始泵送输出，
    /// 失败置 failed，远端结束置 disconnected。
    func connect(using backend: any TerminalBackend) async {
        resetFeedAndResizeState()
        // 重连先复位光标形状（两端共用，见 `TerminalSurfaceLink.prepareForNewConnection`）。
        link.prepareForNewConnection()
        // `resetFeedAndResizeState()` just bumped `feedGeneration`; snapshot it
        // as this call's identity token. The connect below suspends and
        // frees the MainActor — a second `connect(using:)`, `dispose()`, or
        // `detach()` can run during that gap and bump `feedGeneration` again.
        // When this call resumes it must not clobber the newer binding's state.
        let myGen = feedGeneration
        self.backend = backend
        // 尺寸排在建连前面（SSH 当 PTY 初始尺寸，远控主控端的接入请求带上本地网格）；建连期间的键入排在建连后面。
        inputChannel.bind(to: backend, sendingLatestSize: true)
        connectionState = .connecting
        do {
            try await inputChannel.connect(backend)
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
        }
        connectionState = .connected
        // 注册到看门狗：系统唤醒 / 网络恢复后主动探测，半死连接不再顶着
        // 「已连接」徽标静默挂着。弱引用注册，幂等。
        ConnectionWatchdog.shared.register(self)
        inputChannel.sendLatestSizeNow()
        outputPump.start(backend)
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

    /// 清掉屏幕与回滚，不断开后端：之后的输出照常流进同一个终端。
    func clearOutput() {
        // 走泵的分流：影子、镜像、检查点、画面按同一个顺序看到这几个字节。
        outputPump.route(Data("\u{1B}[3J\u{1B}[H\u{1B}[2J".utf8))
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

    /// 代次 +1，停掉在途的入站任务、输入通道与退出监听：上一条连接残留的输出随之作废。
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

/// 输出泵的 tap（喂字节的那条线程）要用、而拥有者在主线程上换的那几样。
nonisolated final class TerminalFeedTaps: @unchecked Sendable {
    private let lock = NSLock()
    private var heldCheckpoints: TerminalHeldCheckpoints?
    private var wantsPinnedNotice = false
    private var noticePending = false
    /// 钉住尺寸期间来了输出：回主线程看一眼光标换行没有。同一时刻最多排一次。
    var onPinnedFeed: (@MainActor () -> Void)?

    var checkpoints: TerminalHeldCheckpoints? {
        get { lock.withLock { heldCheckpoints } }
        set { lock.withLock { heldCheckpoints = newValue } }
    }

    var notifiesPinnedFeed: Bool {
        get { lock.withLock { wantsPinnedNotice } }
        set { lock.withLock { wantsPinnedNotice = newValue } }
    }

    func didFeed(_ count: Int) {
        lock.lock()
        let checkpoints = heldCheckpoints
        let notify = wantsPinnedNotice && !noticePending
        if notify { noticePending = true }
        lock.unlock()
        checkpoints?.noteFed(count)
        guard notify else { return }
        DispatchQueue.main.async {
            self.lock.withLock { self.noticePending = false }
            MainActor.assumeIsolated { self.onPinnedFeed?() }
        }
    }
}
