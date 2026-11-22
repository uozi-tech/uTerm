import SwiftUI
import SwiftData
import Observation
import GhosttyTerminal
import UIKit

/// 用户要不要键盘：亲手收起过就是不要，直到点键盘按钮或点终端要回来。
///
/// 工作区里一格的终端标签共用一份（`MobileWorkspace.keyboardIntent(forPane:)` 下发），所以切标签不改变键盘的收放，
/// 终端也不用跟着改尺寸；分屏的两格各记各的。没接进工作区的控制器（探针、测试）各用各的。
@MainActor
final class MTerminalKeyboardIntent {
    var collapsed = false
}

/// 一个 iOS 终端会话的运行时控制器：持有后端（`TerminalBackend`，生产是 `SSHConnection`）和这条会话的终端
///（`GhosttyTerminalBridge`：GhosttyKit 画面 + 影子终端），把入站字节交给终端、把键盘输入 / 尺寸变化回送后端。
/// `@MainActor` —— 直接安全触碰 SwiftData 模型与 UI。
@MainActor
@Observable
final class MobileTerminalController {
    /// 与 mac `TerminalSession.ConnectionState` 同一个枚举。
    typealias State = TerminalConnectionState

    var state: State = .idle {
        // 离开「已连接」（失败 / 断开 / 重连中）就收起键盘：没有 shell 可打字，
        // 失败态的终端视图还会被失败页替换掉，留着键盘只会盖住失败页。
        didSet {
            if !canTakeKeyboard { resignKeyboard() }
            // 标题说的是那条连接上正在跑的程序，连接没了就不再成立（同 mac `TerminalSession`）。
            if state != .connected {
                shellTitle = nil
                resetProgramStatus()
            }
        }
    }
    /// 本会话是不是此刻唯一该拿键盘的那个（聚焦格的前台标签、终端模式、上面没有连接中页 /
    /// 新建抽屉）。由工作区统一裁决、逐会话下发——每个标签只看自己的这一位。
    var ownsKeyboard = false {
        didSet { if !canTakeKeyboard { resignKeyboard() } }
    }
    /// 键盘只给真正进了终端、且轮到自己的会话：建连中 / 失败 / 已断开 / 不是键盘归属者一律不弹。
    /// 终端视图的 `canBecomeFirstResponder` 也读它，UIKit 自己恢复第一响应者（抽屉收起时）同样被拦。
    var canTakeKeyboard: Bool { state == .connected && ownsKeyboard }
    /// 键盘此刻在这个会话上（终端是第一响应者）。键盘条的收起 / 弹出按钮按它显示。
    private(set) var keyboardShown = false
    /// 用户亲手收起了键盘（`collapsed`）：切标签、关抽屉、转屏都不再自动弹回，直到用户点按钮或点终端。
    /// 同一格的标签共用一份，见 `MTerminalKeyboardIntent`。
    @ObservationIgnored var keyboardIntent = MTerminalKeyboardIntent()
    /// 程序请 uTerm 在旁边预览一个文件（`TerminalFilePreview`，路径在这台主机上）。工作区开标签时装上。
    @ObservationIgnored var onFilePreviewRequest: ((String) -> Void)?
    @ObservationIgnored private var filePreviewThrottle = TerminalFilePreviewThrottle()
    /// shell 或程序用 OSC 0 / 2 设的标题；没设过、设成空、连接已断开时为 nil（标签退回主机名）。
    var shellTitle: String?
    /// 程序用 OSC 7501 报告的状态里最需要人处理的那条；没有或空闲时为 nil（规则与 mac 同一份，
    /// 见 `ProgramStatusTracker`）。远控标签不用它：状态由 Mac 推来，见 `TermTab.programStatus`。
    private(set) var programStatus: ProgramStatusRecord?
    /// 前台是在报告状态的程序（Claude Code / Codex），不是 shell（含空闲态，见 `ProgramStatusTracker.hasRecords`）。
    /// 键盘条按它决定面板里先放「启动」还是先放提示词。远控标签同样不用它，见 `TermTab.agentInForeground`。
    private(set) var agentInForeground = false
    /// 曾经连上过：用于把随后的 `.disconnected` 归为「成功收尾」而非「仍在连接」，
    /// 防止连接中页在「连上即断」时观测不到 `.connected` 而卡死。
    private(set) var hadConnected = false
    /// Ctrl 粘滞修饰是否已「上膛」：键盘条上点 ctrl 后亮起，下一个软键盘字符或键盘条上的键按住 Ctrl 发送
    ///（Ctrl+L / R / C / U、Ctrl+←……）。状态在终端视图里（GhosttyKit 原生的粘滞修饰：用完自动复位，连点两下锁定），
    /// 这里只是给键盘条按钮高亮用的镜像。
    private(set) var controlArmed = false
    /// Alt / Meta 粘滞修饰是否已「上膛」：与 ctrl 对称（Alt+f / b / d / . 等 readline / emacs 词操作）。
    private(set) var altArmed = false

    /// 这条会话的终端：画面（GhosttyKit 的视图）、影子终端、输入通道。强引用——控制器持有它，使其跨「外壳切换 /
    /// TerminalScreen 重建」存活：iPhone Plus / Max 横屏翻 size class 时外壳在 Tab / Split 间切换、TerminalScreen 重建，
    /// 复用同一个视图既不空白也不断连。
    @ObservationIgnored let terminal: GhosttyTerminalBridge
    /// 回滚区查找（两端共用的 `TerminalSearch`，本身可观察）。
    var search: TerminalSearch { terminal.link.search }
    /// 后端按协议持有（`TerminalBackend`，桌面 `TerminalSession` 用的同一个抽象）：
    /// 生产是 `SSHConnection`，测试注入假传输。控制器本身不知道底下是谁。
    @ObservationIgnored private var connection: (any TerminalBackend)?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    /// 连接断了，后端正在自己重连（远控标签连 Mac、直连主机接回主机上的会话）。这期间按键发不出去，界面要明说。
    private(set) var isReconnecting = false
    /// 重连提示的文案：连的是 Mac 还是主机。
    var reconnectNotice: LocalizedStringKey {
        connection is RemoteTerminalBackend ? "与 Mac 的连接已断开，正在重新连接…" : "连接已断开，正在重新连接…"
    }
    /// 主机上那个会话的 id（见 `MobileTerminalTransportRequest.sessionID`）。会话结束（shell 退出、被结束）就换一个：
    /// 之后重新连接开的是新会话。工作区把它记下来，App 重新打开后凭它接回。
    private(set) var hostSessionID: UUID
    /// `hostSessionID` 是上次运行留下的（App 重新打开后恢复的标签）：主机上多半还有这个会话。
    @ObservationIgnored private var resumesHostSession: Bool
    /// 标签已经关了（`close()`）：不再重连。
    @ObservationIgnored private var isClosed = false
    /// 唯一的后端来源。默认 `.live` = 原来内联在 `start()` 里的真 SSH 组装。
    @ObservationIgnored private let transportFactory: MobileTerminalTransportFactory
    @ObservationIgnored private var exitTask: Task<Void, Never>?
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    /// 建连代次：close() / restart() 递增，在途建连落地时对不上就丢弃结果。
    @ObservationIgnored private var connectGeneration = 0
    @ObservationIgnored private var started = false
    /// 该会话是不是**前台**（当前激活标签且处于终端模式）。由 `TerminalSessionBody` 同步。
    ///
    /// `TerminalScreen` 把所有会话常驻挂载（`ZStack { ForEach(tabs) }`，非活动片只是 `opacity(0)` + 移出屏外）。
    /// 不在前台的终端不画（`MTerminalContainerView.isOnScreen` → `setSurfaceVisible(false)`），字节照常解析；
    /// 这里只管「有没有人在看」：远控的重连退避、程序状态的已读。
    var isForeground = true {
        didSet {
            guard isForeground != oldValue else { return }
            syncRemoteWatch()
            if isLooking { acknowledgeProgramStatus() }
        }
    }

    /// 整个 App 在后台（`didEnterBackground` → `willEnterForeground`）。这段时间里 SSH 照常收发
    ///（并行执行靠 `BGContinuedProcessingTask` 续命、或系统给的几十秒），只是谁也看不见终端：
    /// 输出只进影子终端（GhosttyKit 后台不 tick，surface 接着吃会卡死，M10），回到前台把影子的状态回放进画面。
    /// 网络 I/O 不受影响——入站任务不看它。
    @ObservationIgnored private(set) var isAppInBackground = UIApplication.shared.applicationState == .background {
        didSet {
            guard isAppInBackground != oldValue else { return }
            // 只由控制器听这对通知，转给终端（终端自己不听；测试直接调 `appVisibilityChanged` 也走这里）。
            terminal.setAppInBackground(isAppInBackground)
            syncRemoteWatch()
            if isLooking { acknowledgeProgramStatus() }
        }
    }

    /// 进出后台由通知驱动；测试直接调它。
    func appVisibilityChanged(inBackground: Bool) {
        let returned = isAppInBackground && !inBackground
        isAppInBackground = inBackground
        // 回前台：会话在主机上留着的连接立刻查一次，不等看门狗那 3 秒。后台挂久了连接多半已经死了，
        // 判错了也只是多重连一次（画面不动）；普通连接判错就是断开，所以仍然等网络稳了再探。
        if returned { recheckConnection(lostInterface: false) }
        if returned { MobileBackgroundGrace.shared.end() }
        // 进后台：直连主机的会话再留一小段时间（切出去看一眼别的 App 再回来，连接不断）；会话留在主机上的，
        // 把终端此刻的状态存过去——之后 App 被系统结束的话，重新打开凭它接回画面。远控标签不留：
        // 终端在 Mac 上，回来重新接入就是了。
        if inBackground, !returned, state == .connected, let connection, !(connection is RemoteTerminalBackend) {
            MobileBackgroundGrace.shared.begin()
            if let backend = connection as? any CheckpointingTerminalBackend {
                Task { await backend.saveCheckpoint() }
            }
        }
    }

    /// 远控标签：告诉后端此刻有没有人看着它。Mac 长时间离线时，没人看的标签
    /// 重连退避才会放长到最长一分钟；切回来的那一刻后端立刻重试（见 `RemoteReconnectPolicy`）。
    private func syncRemoteWatch() {
        guard let remote = connection as? RemoteTerminalBackend else { return }
        remote.setWatched(isLooking)
        if isLooking { remote.client.acknowledgeProgramStatus(for: remote.sessionID) }
    }

    /// 用户此刻看得见这个终端：前台标签，且 App 在前台。
    var isLooking: Bool { isForeground && !isAppInBackground }

    // nonisolated(unsafe)：在 nonisolated deinit 里清理这两个非 Sendable 的观察者 token。
    // 仅在主线程设置、deinit（无其它引用存活）时读取，无并发访问。
    @ObservationIgnored private nonisolated(unsafe) var backgroundObserver: NSObjectProtocol?
    @ObservationIgnored private nonisolated(unsafe) var foregroundObserver: NSObjectProtocol?

    /// 记下首次建连参数，供失败后 `restart()` 在同一控制器 / 同一终端视图上重连。
    @ObservationIgnored private var lastProfile: ServerProfile?
    @ObservationIgnored private var lastContainer: ModelContainer?
    @ObservationIgnored private var lastRelay: HostKeyChallengeRelay?

    /// `transportFactory` 默认真 SSH——生产侧调用点（`TermTab`）不用改。
    /// `terminal` 默认新建一条接在 App 共用的 ghostty app 上的终端；探针注入自己配好的。
    init(transportFactory: MobileTerminalTransportFactory = .live, terminal: GhosttyTerminalBridge? = nil,
         hostSessionID: UUID? = nil) {
        self.transportFactory = transportFactory
        self.hostSessionID = hostSessionID ?? UUID()
        resumesHostSession = hostSessionID != nil
        self.terminal = terminal ?? GhosttyTerminalBridge()
        installAppVisibilityObservers()
        adoptTerminal()
    }

    /// 用 didEnterBackground / willEnterForeground，不用 resign / becomeActive：拉下控制中心、
    /// 来电横幅、切 App 卡片时 App 只是 inactive，终端还看得见，不能停画。
    private func installAppVisibilityObservers() {
        let center = NotificationCenter.default
        backgroundObserver = center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appVisibilityChanged(inBackground: true) }
        }
        foregroundObserver = center.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appVisibilityChanged(inBackground: false) }
        }
    }

    /// 把终端的回调接到这个会话上：键盘归属、焦点、粘滞修饰、贴图，以及影子终端解析出来的事（标题、程序状态）。
    private func adoptTerminal() {
        terminal.setAppInBackground(isAppInBackground)
        let view = terminal.view
        view.canTakeKeyboard = { [weak self] in self?.canTakeKeyboard ?? false }
        view.onFocusChanged = { [weak self] focused in self?.keyboardFocusChanged(focused) }
        terminal.onStickyModifiersChanged = { [weak self] in self?.syncStickyModifiers() }
        view.onPasteMedia = { [weak self] in
            guard let self, self.acceptsImages else { return }
            let allowsVideo = self.acceptsVideos
            self.sendPaste { try await TerminalPasteSource.clipboard(allowsVideo: allowsVideo) }
        }
        // 程序状态、查询、远控镜像的规则两端共用（`TerminalEventRouter`）。远控标签：Mac 自己回答查询、经远控协议推状态
        // （见 `TermTab.programStatus`），这里不再处理。手机上没有系统通知可发：需要注意的状态只上标签；
        // 不做命令跟踪（OSC 6973 是 Mac 的 CLI 用的）。
        let events = terminal.events
        events.isMirror = { [weak self] in self?.connection?.mirrorsRemoteGrid ?? false }
        events.isLooking = { [weak self] in self?.isLooking ?? false }
        events.sendToProgram = { [weak self] in self?.write($0) }
        events.onStatusChanged = { [weak self] in self?.publishProgramStatus() }
        terminal.onEvent = { [weak self] event in
            switch event {
            case .titleChanged(let title): self?.receiveShellTitle(title)
            case .unknownOSC(let payload, _): self?.receiveFilePreviewRequest(payload)
            default: break
            }
        }
        terminal.onOpenLink = { [weak self] link, kind in self?.openTerminalLink(link, kind: kind) }
        // 手机上没有 ⌘ 点：选中路径 / 网址后编辑菜单里的「打开」。
        view.onOpenLink = { [weak self] link in self?.openTerminalLink(link, kind: .unknown) }
        view.canOpenLink = { [weak self] link in self?.canOpenTerminalLink(link) ?? false }
    }

    /// 选中的链接点了会不会有反应：网址总会；路径要这个标签接了预览，且不是远控镜像（路径在那台 Mac 上）。
    func canOpenTerminalLink(_ link: String) -> Bool {
        switch TerminalLink.classify(link) {
        case .web: return true
        case .unsupported: return false
        case .path: return onFilePreviewRequest != nil && !(connection?.mirrorsRemoteGrid ?? true)
        }
    }

    /// 用户 ⌘ 点了终端里的链接（规则两端共用，见 `TerminalLink`）：网址交给系统，路径解析成主机上的绝对路径后在旁边
    /// 预览。Ghostty 自己写的临时文件（`.text` / `.html`）照旧交给系统。远控镜像的路径在那台 Mac 上，不理。
    func openTerminalLink(_ link: String, kind: TerminalOpenURLKind) {
        switch kind {
        case .text, .html:
            if let url = URL(string: link) { UIApplication.shared.open(url) }
            return
        case .osc8, .unknown:
            break
        }
        switch TerminalLink.classify(link) {
        case .web(let url):
            UIApplication.shared.open(url)
        case .path(let raw):
            guard onFilePreviewRequest != nil, let connection, !connection.mirrorsRemoteGrid else { return }
            let reported = terminal.shadow.workingDirectory
            Task { [weak self] in
                guard let path = await TerminalLinkResolver.absolutePath(raw, reportedDirectory: reported,
                                                                         backend: connection) else { return }
                self?.onFilePreviewRequest?(path)
            }
        case .unsupported:
            break
        }
    }

    /// 程序请在旁边预览一个文件（`TerminalFilePreview`）。远控镜像不理：路径在被控的那台 Mac 上，手机经 SSH 读不到。
    private func receiveFilePreviewRequest(_ payload: Data) {
        guard let path = TerminalFilePreview.path(fromOSC: payload),
              let handler = onFilePreviewRequest,
              !(connection?.mirrorsRemoteGrid ?? false),
              filePreviewThrottle.admits(path) else { return }
        handler(path)
    }

    // MARK: 程序状态（OSC 7501 / 133）

    /// 用户看到结果了：`done` / `error` 不再上标签。
    func acknowledgeProgramStatus() {
        terminal.events.acknowledgeResults()
    }

    private func resetProgramStatus() {
        terminal.events.reset()
    }

    private func publishProgramStatus() {
        let next = terminal.events.tracker.display
        if next != programStatus { programStatus = next }
        let agent = terminal.events.tracker.hasRecords
        if agent != agentInForeground { agentInForeground = agent }
    }

    // MARK: Ctrl / Alt 粘滞修饰

    /// 点 ctrl 键：切换「上膛」状态。
    func toggleControl() {
        terminal.toggleControl()
        syncStickyModifiers()
    }

    /// 点 alt 键：切换「上膛」状态。
    func toggleAlt() {
        terminal.toggleAlt()
        syncStickyModifiers()
    }

    /// 取消所有粘滞修饰。发提示词前调用：提示词是一段文字，修饰键作用不到它上面，留着只会落到用户接下来打的第一个字上。
    /// 键盘条上的键不用清：修饰作用在那个键上（Ctrl+←），用完自己复位。
    func clearStickyModifiers() {
        terminal.clearStickyModifiers()
        syncStickyModifiers()
    }

    /// 键盘条上的一个键：交给终端按当前模式编码（应用光标键下方向键发 `ESC O A`），上膛的修饰键一并带上。
    func sendKey(_ key: TerminalKey) {
        terminal.send(key)
    }

    private func syncStickyModifiers() {
        let (control, alt) = terminal.stickyModifiers
        if control != controlArmed { controlArmed = control }
        if alt != altArmed { altArmed = alt }
    }

    /// 关闭会话前先收起键盘——否则视图随转场移除后键盘还会残留几百毫秒。
    func resignKeyboard() {
        _ = terminal.view.resignFirstResponder()
    }

    /// 切到该会话标签时让其终端重新成为第一响应者（弹回键盘）。未连上、或用户收起了键盘时不弹。
    func focusKeyboard() {
        guard canTakeKeyboard, !keyboardIntent.collapsed else { return }
        _ = terminal.view.becomeFirstResponder()
    }

    /// 用户点了「收起键盘」。
    func collapseKeyboard() {
        keyboardIntent.collapsed = true
        resignKeyboard()
    }

    /// 用户点了「弹出键盘」。分屏时这一格可能还没拿到归属，工作区把焦点切过来后会再聚焦一次。
    func showKeyboard() {
        keyboardIntent.collapsed = false
        focusKeyboard()
    }

    /// 终端视图报告第一响应者变化。点终端（视图自己聚焦）也走这里，等于用户要回了键盘。
    func keyboardFocusChanged(_ focused: Bool) {
        keyboardShown = focused
        if focused { keyboardIntent.collapsed = false }
    }

    /// 用一台主机建连并开 PTY。重复调用无副作用（已建连过则忽略）。
    /// `relay` 把首次连接 / 密钥变化的 host-key 挑战交给用户裁决（替代盲信 TOFU）。
    func start(profile: ServerProfile, container: ModelContainer, relay: HostKeyChallengeRelay) {
        guard !started else { return }
        started = true
        state = .connecting
        lastProfile = profile; lastContainer = container; lastRelay = relay
        connectGeneration &+= 1
        let attempt = connectGeneration
        // 不在库里的主机（Mac 本机 shell 的临时主机）不记「最近连接」：拿临时 id 去库里取会取到故障对象。
        let pid: PersistentIdentifier? = profile.modelContext == nil ? nil : profile.persistentModelID
        let request = MobileTerminalTransportRequest(profile: profile, container: container, relay: relay,
                                                     sessionID: hostSessionID, resumesSession: resumesHostSession)

        let factory = transportFactory
        // 全程弱引用：握手最长要等到登录超时，不能让一个已关掉的标签被这段等待拖住。
        connectTask = Task { [weak self] in
            let made: Result<any TerminalBackend, any Error>
            do { made = .success(try await factory.make(request)) } catch { made = .failure(error) }
            guard let conn = self?.adopt(made, attempt: attempt), let input = self?.terminal.input else { return }
            // 经输入通道建连：接上时排进去的尺寸先到（远控标签的接入请求带上本地网格，见 `TerminalInputChannel.connect`）。
            let outcome: (any Error)?
            do { try await input.connect(conn); outcome = nil } catch { outcome = error }
            self?.finishConnect(outcome, attempt: attempt, pid: pid, container: container)
        }
    }

    /// 工厂结果落地。解析钥匙串期间被 close() / restart() 了（代次对不上）就丢掉——
    /// 这条传输还没连，随引用释放即可。
    private func adopt(_ made: Result<any TerminalBackend, any Error>, attempt: Int) -> (any TerminalBackend)? {
        guard connectGeneration == attempt else { return nil }
        switch made {
        case .success(let conn):
            install(conn)
            return conn
        case .failure(let error):
            // 工厂只会从认证材料解析那一步抛错（与抽工厂之前同义）。
            state = .failed(String(localized: "凭据解析失败：\(error.localizedDescription)"))
            return nil
        }
    }

    /// 握手结果落地。握手期间被关闭 / 被重连取代时不能把 `.disconnected` 翻回 `.connected`。
    private func finishConnect(_ error: (any Error)?, attempt: Int,
                               pid: PersistentIdentifier?, container: ModelContainer) {
        guard connectGeneration == attempt else { return }
        if let error {
            state = .failed(error.localizedDescription)
            return
        }
        state = .connected
        hadConnected = true
        // 远控终端接上之后才知道是不是 Mac 的本机 shell（只有它收文件）。
        refreshMediaCapabilities()
        // 回前台 / 换网络 / 每 30s 探一次活：后台挂久了的半死 TCP 不会自己报错，
        // 标签一直显示「已连接」、输入只进内核缓冲。判死后走 exitStream → `.disconnected`。
        ConnectionWatchdog.shared.register(self)
        if let pid, let profile = container.mainContext.model(for: pid) as? ServerProfile {
            profile.lastConnectedAt = Date()
            try? container.mainContext.save()
        }
    }

    /// 接上一条刚造好的传输：输出泵、退出监听、有序的输入通道。
    private func install(_ conn: any TerminalBackend) {
        connection = conn
        isReconnecting = false
        reconnectTask?.cancel()
        reconnectTask = (conn as? any ReconnectingTerminalBackend).map { backend in
            Task { [weak self] in
                for await reconnecting in backend.reconnecting { self?.isReconnecting = reconnecting }
                self?.isReconnecting = false
            }
        }
        if let remote = conn as? RemoteTerminalBackend {
            remote.client.setProgramStatusLooker(remote.sessionID) { [weak self] in self?.isLooking ?? false }
        }
        syncRemoteWatch()
        refreshMediaCapabilities()
        if let backend = conn as? any CheckpointingTerminalBackend {
            let pump = terminal.outputPump, events = terminal.events
            backend.setCheckpointHooks(TerminalCheckpointHooks(
                capture: {
                    pump.makeCheckpoint(scrollbackLines: HostHolder.checkpointScrollbackLines,
                                        programStatus: events.journal.encoded)
                },
                restoreProgramStatus: { events.restoreFromCheckpoint($0) }))
        }
        let exitStream = conn.exitStream
        // 输出进终端（影子同步解析，画面在 GhosttyKit 自己的串行队列上解析、按 vsync 画）；击键 / 尺寸变化走终端的
        // 同一条 FIFO。尺寸可能早于传输就绪（首次排布、重连），接上时先补发。
        terminal.bind(conn)
        exitTask = Task { [weak self] in
            for await _ in exitStream {
                // 主机上的会话没了：之后重新连接开的是新会话。
                self?.hostSessionID = UUID()
                self?.resumesHostSession = false
                if case .failed = self?.state { } else { self?.state = .disconnected }
                break
            }
        }
    }

    func write(_ data: Data) {
        terminal.write(data)
    }

    // MARK: - 图片

    private func refreshMediaCapabilities() {
        acceptsImages = connection is any TerminalImageReceiving
        acceptsVideos = (connection as? any TerminalVideoReceiving)?.receivesFiles ?? false
    }

    /// 后端能不能收图片：直连 SSH 传成服务器上的文件；远控 Mac 终端交给 Mac（本机 shell 走剪贴板 +
    /// Ctrl+V，SSH 会话由 Mac 传文件）。测试的假传输不能。
    private(set) var acceptsImages = false
    /// 后端能不能收视频和别的文件：直连 SSH（传成服务器上的文件）与远控 Mac 的本机 shell（传到 Mac 的 `/private/tmp`）。
    /// Mac 上的 SSH 终端不能（见 `TerminalVideoReceiving`），键盘条对它只给贴图片。
    private(set) var acceptsVideos = false
    /// 贴图的进度 / 结果（键盘条上方的提示）。进行中带进度条；出了结果几秒后自己消失。
    private(set) var imageNote: PasteNote?
    @ObservationIgnored private var imageNoteTask: Task<Void, Never>?
    /// 一次贴一样：上一个还在路上时再点不另起一次（两条进度会互相盖掉）。
    @ObservationIgnored private var sendingImage = false

    /// 键盘条「从剪贴板粘贴」：有图片 / 视频就传给终端里的程序（同 `onPasteMedia`）；没有就按系统粘贴送文字；
    /// 再没有、是在「文件」里拷贝的文件，就按文件传。后端收不了图片（测试的假传输）时只贴文字。
    /// 只看类型决定走哪条（不读内容），读文字时系统照常问「允许粘贴」。
    func pasteClipboard(_ board: UIPasteboard = .general) {
        if acceptsImages, board.hasImages || TerminalPasteSource.hasVideo(board) {
            let allowsVideo = acceptsVideos
            sendPaste { try await TerminalPasteSource.clipboard(allowsVideo: allowsVideo, board: board) }
        } else if board.hasStrings {
            if let text = board.string, !text.isEmpty { paste(text) }
        } else if acceptsImages, TerminalPasteSource.hasFile(board) {
            let allowsFiles = acceptsVideos
            sendPaste { try await TerminalPasteSource.clipboardFile(allowsFiles: allowsFiles, board: board) }
        } else {
            showImageNote(TerminalPasteSource.Failure.empty.localizedDescription)
        }
    }

    /// 读一张图、一段视频或一个文件（剪贴板 / 相册 / 「文件」）交给终端里的程序。传成文件时把路径粘进终端，后面带一个空格。
    /// 读取、压缩、上传都不在主线程上做，各段的进度经 `PasteProgressReporter` 画到提示里的进度条上。
    /// 视频的本机拷贝送完（成败都算）就删掉。
    func sendPaste(_ load: @escaping @MainActor () async throws -> TerminalPasteItem) {
        guard let backend = connection, acceptsImages, state == .connected, !sendingImage else { return }
        sendingImage = true
        showImageNote(PasteProgress(.reading).note)
        let relay = PasteProgressRelay { [weak self] progress in self?.imageProgressChanged(progress) }
        Task { [weak self] in
            defer { self?.sendingImage = false }
            do {
                let note = try await PasteProgressReporter.$sink.withValue(relay.sink) {
                    try await Self.deliver(try await load(), to: backend) { self?.paste($0) }
                }
                self?.showImageNote(note)
            } catch {
                self?.showImageNote(error.localizedDescription)
            }
        }
    }

    /// 送一样东西，返回结果提示。
    private static func deliver(_ item: TerminalPasteItem, to backend: any TerminalBackend,
                                paste: @MainActor (String) -> Void) async throws -> String {
        switch item {
        case .image(let image):
            guard let receiver = backend as? any TerminalImageReceiving else { throw TerminalImageError.notConnected }
            switch try await TerminalPaste.deliver(image: image, to: receiver, paste: paste) {
            case .clipboard: return String(localized: "图片已放入 Mac 剪贴板，并已发送 Ctrl+V")
            case .file(let path): return String(localized: "图片已上传到 \(path)")
            }
        case .video(let video):
            defer { video.discardLocalCopy() }
            guard let receiver = backend as? any TerminalVideoReceiving else {
                throw video.kind == .video ? TerminalPasteSource.Failure.videoUnsupported
                    : TerminalPasteSource.Failure.fileUnsupported
            }
            let path = try await TerminalPaste.deliver(video: video, to: receiver, paste: paste)
            switch video.kind {
            case .video: return String(localized: "视频已上传到 \(path)")
            case .file: return String(localized: "文件已上传到 \(path)")
            }
        }
    }

    /// 像系统粘贴一样送一段文字：终端开了 bracketed paste 就包上起止标记（程序据此认出是粘贴，
    /// 例如 Claude Code 把粘进来的图片路径当附件）。
    func paste(_ text: String) {
        terminal.paste(text)
    }

    /// 进度只往进行中的那条提示上走：结果已经出来（提示没了进度条）之后晚到的不再把进度条拉回来。
    private func imageProgressChanged(_ progress: PasteProgress) {
        guard let current = imageNote?.progress, progress.overall >= current else { return }
        imageNote = progress.note
    }

    private func showImageNote(_ text: String) {
        showImageNote(PasteNote(text: text))
    }

    /// 带进度的（进行中）一直留着，直到换成结果；结果几秒后自己消失。
    private func showImageNote(_ note: PasteNote) {
        imageNoteTask?.cancel()
        imageNote = note
        guard note.progress == nil else { return }
        imageNoteTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.imageNote = nil
        }
    }

    /// 收 OSC 0 / 2 标题：规整后为空就清掉（程序清空标题时标签回到主机名）。
    func receiveShellTitle(_ title: String) {
        let next = TerminalTitle.normalize(title)
        guard next != shellTitle else { return }
        shellTitle = next
    }

    func sendText(_ text: String) {
        write(Data(text.utf8))
    }

    /// 把提示词交给终端里的程序，不提交。程序开了括号粘贴就按粘贴发，一次到达不会被拆开解读。
    func insertPrompt(_ text: String) {
        paste(text)
    }

    /// 发送提示词并提交。回车隔一下单独发（见 `AgentPromptSubmit.enterDelay`）。
    func submitPrompt(_ text: String) {
        insertPrompt(text)
        Task { [weak self] in
            try? await Task.sleep(for: AgentPromptSubmit.enterDelay)
            self?.sendText("\r")
        }
    }

    func close() {
        isClosed = true
        teardownConnection()
        state = .disconnected
    }

    /// 关标签前问：前台还有没有程序在跑。没连上就没有程序可中断。
    func foregroundActivity() async -> TerminalActivity {
        await TerminalCloseProbe.foregroundActivity(connected: state == .connected, backend: connection) {
            terminal.shadow.isOnAlternateScreen
        }
    }

    /// 能不能在这个标签上重新连接：建连失败了，或者连上之后断开了（shell 退出、连接断了）。
    var canReconnect: Bool {
        guard !isClosed else { return false }
        switch state {
        case .failed: return lastProfile != nil
        case .disconnected: return hadConnected && lastProfile != nil
        case .idle, .connecting, .connected: return false
        }
    }

    /// 失败 / 断开后在同一控制器 / 同一终端视图上重连（连接中页「重试」、断开提示上的「重新连接」）。
    /// 终端视图仍挂着，新连接的输出接着喂给它。
    func restart() {
        guard canReconnect,
              let profile = lastProfile, let container = lastContainer, let relay = lastRelay else { return }
        teardownConnection()
        started = false
        state = .idle
        start(profile: profile, container: container, relay: relay)
    }

    /// 作废在途建连（代次 +1，晚到的结果一律丢弃），拆掉终端与后端之间的输出 / 输入，再关传输。
    private func teardownConnection() {
        connectGeneration &+= 1
        connectTask?.cancel()
        connectTask = nil
        exitTask?.cancel()
        reconnectTask?.cancel()
        reconnectTask = nil
        isReconnecting = false
        if let remote = connection as? RemoteTerminalBackend {
            remote.client.setProgramStatusLooker(remote.sessionID, nil)
        }
        terminal.unbind()
        let conn = connection
        Task { await conn?.close() }
        connection = nil
    }

    deinit {
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
        if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
        // 终端（入站任务、输入通道）随控制器释放，自己的 deinit 收尾。
        exitTask?.cancel(); connectTask?.cancel()
    }
}

extension MobileTerminalController: ConnectionHealthProbing {
    func probeConnectionHealth() async {
        await state.probeHealth(of: connection)
    }

    /// 网络刚变（Wi-Fi ↔ 蜂窝）：能自己接回的连接立刻处置，不等看门狗的稳定期和探活时限。
    func networkPathChanged(lostInterface: Bool) {
        recheckConnection(lostInterface: lostInterface)
    }

    private func recheckConnection(lostInterface: Bool) {
        guard state == .connected, let backend = connection as? any ReconnectingTerminalBackend else { return }
        Task { await backend.recheckAfterDisruption(lostInterface: lostInterface) }
    }
}
