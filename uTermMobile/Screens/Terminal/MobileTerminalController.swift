import SwiftUI
import SwiftData
import SwiftTerm
import Observation

/// 一个 iOS 终端会话的运行时控制器：持有 `SSHConnection`（复用 macOS 端
/// `TerminalBackend` 实现），把入站字节喂给 SwiftTerm 的 `TerminalView`，并把
/// 键盘输入 / 尺寸变化回送后端。`@MainActor` —— 直接安全触碰 SwiftData 模型与 UI。
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
    /// 用户亲手收起了键盘：切标签、关抽屉、转屏都不再自动弹回，直到用户点按钮或点终端。
    @ObservationIgnored private var keyboardCollapsed = false
    /// shell 或程序用 OSC 0 / 2 设的标题；没设过、设成空、连接已断开时为 nil（标签退回主机名）。
    var shellTitle: String?
    /// 程序用 OSC 7501 报告的状态里最需要人处理的那条；没有或空闲时为 nil（规则与 mac 同一份，
    /// 见 `ProgramStatusTracker`）。远控标签不用它：状态由 Mac 推来，见 `TermTab.programStatus`。
    private(set) var programStatus: ProgramStatusRecord?
    @ObservationIgnored private var programStatusTracker = ProgramStatusTracker()
    /// 已经注册过程序状态处理器的终端视图（横屏切外壳时视图复用，不重复注册）。
    @ObservationIgnored private weak var programStatusView: SwiftTerm.TerminalView?
    /// 曾经连上过：用于把随后的 `.disconnected` 归为「成功收尾」而非「仍在连接」，
    /// 防止连接中页在「连上即断」时观测不到 `.connected` 而卡死。
    private(set) var hadConnected = false
    /// Ctrl 粘滞修饰是否已「上膛」：键盘条上点 ctrl 后亮起，下一个软键盘字符按住 Ctrl 发送
    ///（Ctrl+L/R/C/U……）。底层复用 SwiftTerm `TerminalView.controlModifier`——它在 insertText
    /// 里消费并自动复位，复位时发 `.terminalViewControlModifierReset`，据此把按钮高亮同步关掉。
    var controlArmed = false
    /// Alt/Meta 粘滞修饰是否已「上膛」：与 ctrl 对称，下一个软键盘字符前发 ESC 前缀
    ///（Alt+f/b/d/. 等 readline/emacs 词操作）。底层复用 SwiftTerm `TerminalView.metaModifier`——
    /// 它在 insertText 里发 `\u{1b}` + 字符并自动复位，复位时发 `.terminalViewMetaModifierReset`。
    /// 注：粘滞修饰只作用于系统软键盘字符；点键盘条上的快捷键会先 `clearStickyModifiers()`。
    var altArmed = false

    // 强引用：控制器持有终端视图，使其跨「外壳切换 / TerminalScreen 重建」存活，保活
    // SwiftTerm 内部的屏幕缓冲与回滚——iPhone Plus/Max 横屏翻 size class 时外壳在
    // Tab/Split 间切换、TerminalScreen 重建，复用同一视图既不空白也不断连。
    // 无循环引用：SwiftTerm 的 `terminalDelegate` 是 weak，view 不强持 coordinator。
    @ObservationIgnored private(set) var terminalView: SwiftTerm.TerminalView?
    /// 后端按协议持有（`TerminalBackend`，桌面 `TerminalSession` 用的同一个抽象）：
    /// 生产是 `SSHConnection`，测试注入假传输。控制器本身不知道底下是谁。
    @ObservationIgnored private var connection: (any TerminalBackend)?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    /// 远控标签与 Mac 的连接断了，正在重连。这期间按键发不出去，界面要明说。
    private(set) var isReconnecting = false
    /// 唯一的后端来源。默认 `.live` = 原来内联在 `start()` 里的真 SSH 组装。
    @ObservationIgnored private let transportFactory: MobileTerminalTransportFactory
    /// 输出泵与输入 / 尺寸通道，两端共用（`TerminalOutputPump` / `TerminalInputChannel`）。
    @ObservationIgnored private let outputPump = TerminalOutputPump(pacing: .foreground)
    @ObservationIgnored private let inputChannel = TerminalInputChannel()
    @ObservationIgnored private var exitTask: Task<Void, Never>?
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    /// 建连代次：close() / restart() 递增，在途建连落地时对不上就丢弃结果。
    @ObservationIgnored private var connectGeneration = 0
    @ObservationIgnored private var started = false
    /// 该会话是不是**前台**（当前激活标签且处于终端模式）。由 `TerminalSessionBody` 同步。
    ///
    /// `TerminalScreen` 把所有会话常驻挂载（`ZStack { ForEach(tabs) }`，非活动片只是
    /// `opacity(0)` + 移出屏外），所以后台会话的终端视图**照样每 16ms 被 feed 一次、
    /// 照样重绘**。探针实测：4 个会话各 2000 行/秒时，只有一个在吐 vs 四个都在吐，
    /// 主线程单帧 p50 0.06ms → 3.94ms、超 8.33ms 帧 0% → 16.6%（`term-ab-*`）。
    ///
    /// 修法是**降频**：后台会话把 feed 节拍从 16ms 降到 64ms，单次 drain 相应放大，
    /// 不再每 16ms 逼 SwiftTerm 解析 + 重绘一次。切回前台立刻重启泵，把那一段
    /// 等待截断。
    var isForeground = true {
        didSet {
            guard isForeground != oldValue else { return }
            updatePacing()
            syncRemoteWatch()
            if isLooking { acknowledgeProgramStatus() }
        }
    }

    /// 整个 App 在后台（`didEnterBackground` → `willEnterForeground`）。这段时间里 SSH 照常收发
    ///（并行执行靠 `BGContinuedProcessingTask` 续命、或系统给的几十秒），只是谁也看不见终端：
    /// 前台标签也按后台档喂（64ms 一拍，主线程每秒醒 16 次而不是 60 次），终端视图不画。
    /// 字节一个不少照常解析，回到前台立刻重起泵、补画一次。网络 I/O 不受影响——入站任务不看它。
    @ObservationIgnored private(set) var isAppInBackground = UIApplication.shared.applicationState == .background {
        didSet {
            guard isAppInBackground != oldValue else { return }
            (terminalView as? MTerminalView)?.isAppInBackground = isAppInBackground
            updatePacing()
            syncRemoteWatch()
            if isLooking { acknowledgeProgramStatus() }
        }
    }

    /// 进出后台由通知驱动；测试直接调它。
    func appVisibilityChanged(inBackground: Bool) {
        isAppInBackground = inBackground
    }

    /// 只有「前台标签 + App 在前台」才按 16ms 喂。
    nonisolated static func pacing(isForeground: Bool, isAppInBackground: Bool) -> TerminalFlushPacing {
        isForeground && !isAppInBackground ? .foreground : .background
    }

    private func updatePacing() {
        let next = Self.pacing(isForeground: isForeground, isAppInBackground: isAppInBackground)
        guard next != outputPump.pacing else { return }
        outputPump.pacing = next
        // 换到前台档时截断后台档那一拍的等待。
        if next == .foreground { outputPump.restartFlushLoop() }
    }

    /// 远控标签：告诉后端此刻有没有人看着它（与按前台档喂字节同一个判定）。Mac 长时间离线时，没人看的标签
    /// 重连退避才会放长到最长一分钟；切回来的那一刻后端立刻重试（见 `RemoteReconnectPolicy`）。
    private func syncRemoteWatch() {
        guard let remote = connection as? RemoteTerminalBackend else { return }
        remote.setWatched(isLooking)
        remote.client.setProgramStatusWatched(remote.sessionID, isLooking)
    }

    /// 用户此刻看得见这个终端：前台标签，且 App 在前台。
    var isLooking: Bool { isForeground && !isAppInBackground }

    typealias FlushPacing = TerminalFlushPacing
    // nonisolated(unsafe)：在 nonisolated deinit 里清理这两个非 Sendable 的观察者 token。
    // 仅在主线程设置、deinit（无其它引用存活）时读取，无并发访问。
    @ObservationIgnored private nonisolated(unsafe) var ctrlResetObserver: NSObjectProtocol?
    @ObservationIgnored private nonisolated(unsafe) var metaResetObserver: NSObjectProtocol?
    @ObservationIgnored private nonisolated(unsafe) var backgroundObserver: NSObjectProtocol?
    @ObservationIgnored private nonisolated(unsafe) var foregroundObserver: NSObjectProtocol?

    /// 记下首次建连参数，供失败后 `restart()` 在同一控制器 / 同一终端视图上重连。
    @ObservationIgnored private var lastProfile: ServerProfile?
    @ObservationIgnored private var lastContainer: ModelContainer?
    @ObservationIgnored private var lastRelay: HostKeyChallengeRelay?

    /// `transportFactory` 默认真 SSH——生产侧调用点（`TermTab`）不用改。
    init(transportFactory: MobileTerminalTransportFactory = .live) {
        self.transportFactory = transportFactory
        installAppVisibilityObservers()
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

    func attach(_ view: SwiftTerm.TerminalView) {
        terminalView = view
        outputPump.terminalView = view
        (view as? MTerminalView)?.isAppInBackground = isAppInBackground
        // 远控快照带这么多行历史，接收端要装得下（SwiftTerm 默认只有 500 行）。
        let terminal = view.getTerminal()
        if (terminal.options.scrollback) < RemoteConstants.snapshotScrollback {
            terminal.changeScrollback(RemoteConstants.snapshotScrollback)
        }
        installModifierResetObserversIfNeeded()
        installProgramStatusHandlers(on: view)
    }

    // MARK: 程序状态（OSC 7501 / 133）

    private func installProgramStatusHandlers(on view: SwiftTerm.TerminalView) {
        guard programStatusView !== view else { return }
        programStatusView = view
        ProgramStatusOSC.install(on: view.getTerminal(), onMessage: { [weak self] message in
            // 远控标签：Mac 自己回答查询、经远控协议推状态。这里再答一遍就成了 Mac 上的程序收到的多余输入。
            guard let self, !(self.connection is RemoteTerminalBackend) else { return }
            self.applyProgramStatus(message)
        }, onPrompt: { [weak self] in
            guard let self else { return }
            self.programStatusTracker.promptStarted()
            self.publishProgramStatus()
        })
    }

    /// 手机上没有系统通知可发：需要注意的状态只上标签。
    func applyProgramStatus(_ message: ProgramStatusMessage) {
        if programStatusTracker.receive(message, isLooking: isLooking) == .reply {
            write(Data(ProgramStatusTracker.queryReply))
        }
        publishProgramStatus()
    }

    /// 用户看到结果了：`done` / `error` 不再上标签。
    func acknowledgeProgramStatus() {
        programStatusTracker.acknowledgeResults()
        publishProgramStatus()
    }

    private func resetProgramStatus() {
        programStatusTracker.reset()
        publishProgramStatus()
    }

    private func publishProgramStatus() {
        let next = programStatusTracker.display
        if next != programStatus { programStatus = next }
    }

    // MARK: Ctrl / Alt 粘滞修饰

    /// 点 ctrl 键：切换「上膛」状态并同步给 SwiftTerm 视图。
    func toggleControl() {
        controlArmed.toggle()
        terminalView?.controlModifier = controlArmed
    }

    /// 点 alt 键：切换「上膛」状态并同步给 SwiftTerm 视图。
    func toggleAlt() {
        altArmed.toggle()
        terminalView?.metaModifier = altArmed
    }

    /// 取消待生效的 Ctrl（点了其它快捷键时调用，避免 Ctrl 漏到后续按键）。
    func clearControl() {
        guard controlArmed else { return }
        controlArmed = false
        terminalView?.controlModifier = false
    }

    /// 取消待生效的 Alt。
    func clearAlt() {
        guard altArmed else { return }
        altArmed = false
        terminalView?.metaModifier = false
    }

    /// 取消所有粘滞修饰（点键盘条快捷键前调用——修饰只作用于系统软键盘字符）。
    func clearStickyModifiers() {
        clearControl()
        clearAlt()
    }

    /// SwiftTerm 在软键盘按下后会把 control/meta 修饰复位并发通知；据此关掉按钮高亮。
    private func installModifierResetObserversIfNeeded() {
        if ctrlResetObserver == nil {
            ctrlResetObserver = NotificationCenter.default.addObserver(
                forName: .terminalViewControlModifierReset, object: nil, queue: .main
            ) { [weak self] note in
                // queue: .main → 必在主线程回调，可直接断言 MainActor 同步触碰 UI 状态。
                // 只把 Sendable 的对象身份带过隔离边界（不要把非 Sendable 的 note 捕获进 MainActor 闭包）。
                let objID = (note.object as AnyObject?).map(ObjectIdentifier.init)
                MainActor.assumeIsolated {
                    guard let self, let tv = self.terminalView,
                          objID == ObjectIdentifier(tv) else { return }
                    self.controlArmed = false
                }
            }
        }
        if metaResetObserver == nil {
            metaResetObserver = NotificationCenter.default.addObserver(
                forName: .terminalViewMetaModifierReset, object: nil, queue: .main
            ) { [weak self] note in
                let objID = (note.object as AnyObject?).map(ObjectIdentifier.init)
                MainActor.assumeIsolated {
                    guard let self, let tv = self.terminalView,
                          objID == ObjectIdentifier(tv) else { return }
                    self.altArmed = false
                }
            }
        }
    }

    /// 关闭会话前先收起键盘——否则视图随转场移除后键盘还会残留几百毫秒。
    func resignKeyboard() {
        _ = terminalView?.resignFirstResponder()
    }

    /// 切到该会话标签时让其终端重新成为第一响应者（弹回键盘）。未连上、或用户收起了键盘时不弹。
    func focusKeyboard() {
        guard canTakeKeyboard, !keyboardCollapsed else { return }
        _ = terminalView?.becomeFirstResponder()
    }

    /// 用户点了「收起键盘」。
    func collapseKeyboard() {
        keyboardCollapsed = true
        resignKeyboard()
    }

    /// 用户点了「弹出键盘」。分屏时这一格可能还没拿到归属，工作区把焦点切过来后会再聚焦一次。
    func showKeyboard() {
        keyboardCollapsed = false
        focusKeyboard()
    }

    /// 终端视图报告第一响应者变化。点终端（SwiftTerm 自己聚焦）也走这里，等于用户要回了键盘。
    func keyboardFocusChanged(_ focused: Bool) {
        keyboardShown = focused
        if focused { keyboardCollapsed = false }
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
        let request = MobileTerminalTransportRequest(profile: profile, container: container, relay: relay)

        let factory = transportFactory
        // 全程弱引用：握手最长要等到登录超时，不能让一个已关掉的标签被这段等待拖住。
        connectTask = Task { [weak self] in
            let made: Result<any TerminalBackend, any Error>
            do { made = .success(try await factory.make(request)) } catch { made = .failure(error) }
            guard let conn = self?.adopt(made, attempt: attempt) else { return }
            let outcome: (any Error)?
            do { try await conn.connect(); outcome = nil } catch { outcome = error }
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
            state = .failed("凭据解析失败：\(error.localizedDescription)")
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
        reconnectTask = (conn as? RemoteTerminalBackend).map { remote in
            Task { [weak self] in
                for await reconnecting in remote.reconnecting { self?.isReconnecting = reconnecting }
                self?.isReconnecting = false
            }
        }
        syncRemoteWatch()
        acceptsImages = conn is any TerminalImageReceiving
        let exitStream = conn.exitStream
        outputPump.reset()
        outputPump.start(conn.outputStream)
        exitTask = Task { [weak self] in
            for await _ in exitStream {
                if case .failed = self?.state { } else { self?.state = .disconnected }
                break
            }
        }

        // 击键 / 尺寸变化走同一条 FIFO。尺寸可能早于传输就绪（首次排布、重连），接上时先补发。
        inputChannel.bind(to: conn, sendingLatestSize: true)
    }

    func write(_ data: Data) {
        inputChannel.write(data)
    }

    // MARK: - 图片

    /// 后端能不能收图片：直连 SSH 传成服务器上的文件；远控 Mac 终端交给 Mac（本机 shell 走剪贴板 +
    /// Ctrl+V，SSH 会话由 Mac 传文件）。测试的假传输不能。
    private(set) var acceptsImages = false
    /// 贴图的进度 / 结果（键盘条上方的提示），几秒后自己消失。
    private(set) var imageNote: String?
    @ObservationIgnored private var imageNoteTask: Task<Void, Never>?

    /// 读一张图（剪贴板 / 相册）交给终端里的程序。传成文件时把路径粘进终端，后面带一个空格。
    func sendImage(_ load: @escaping @MainActor () async throws -> TerminalImage) {
        guard let receiver = connection as? any TerminalImageReceiving, state == .connected else { return }
        showImageNote("正在发送图片…", sticky: true)
        Task { [weak self] in
            do {
                let image = try await load()
                let delivery = try await TerminalPaste.deliver(image: image, to: receiver) { self?.paste($0) }
                guard let self else { return }
                switch delivery {
                case .clipboard:
                    self.showImageNote("图片已放入 Mac 剪贴板，并已发送 Ctrl+V")
                case .file(let path):
                    self.showImageNote("图片已上传到 \(path)")
                }
            } catch {
                self?.showImageNote(error.localizedDescription)
            }
        }
    }

    /// 像系统粘贴一样送一段文字：终端开了 bracketed paste 就包上起止标记（程序据此认出是粘贴，
    /// 例如 Claude Code 把粘进来的图片路径当附件）。
    func paste(_ text: String) {
        write(TerminalPaste.wrap(text, bracketed: bracketedPasteMode))
    }

    /// 终端里的程序有没有开括号粘贴（DECSET 2004）。
    private var bracketedPasteMode: Bool {
        terminalView?.getTerminal().bracketedPasteMode ?? false
    }

    private func showImageNote(_ note: String, sticky: Bool = false) {
        imageNoteTask?.cancel()
        imageNote = note
        guard !sticky else { return }
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

    /// 发送提示词并提交。回车必须隔一下单独发：Codex 把和文字同一包到达的回车当粘贴里的换行，
    /// 文字留在输入框不提交（实测 Codex 0.166.0）。
    func submitPrompt(_ text: String) {
        insertPrompt(text)
        Task { [weak self] in
            try? await Task.sleep(for: Self.promptSubmitDelay)
            self?.sendText("\r")
        }
    }
    private static let promptSubmitDelay = Duration.milliseconds(120)

    /// 把新尺寸告诉远端：只合并同一轮主线程里的连续变化，和上次发出的相同就不发（见 `TerminalInputChannel`）。
    func resize(cols: UInt16, rows: UInt16) {
        inputChannel.reportSize(cols: cols, rows: rows)
    }

    func close() {
        teardownConnection()
        state = .disconnected
    }

    /// 关标签前问：前台还有没有程序在跑。没连上就没有程序可中断。
    func foregroundActivity() async -> TerminalActivity {
        await TerminalCloseProbe.foregroundActivity(connected: state == .connected, backend: connection) {
            terminalView?.getTerminal().isCurrentBufferAlternate ?? false
        }
    }

    /// 失败后在同一控制器 / 同一终端视图上重连（连接中页「重试」）。终端视图仍挂着，
    /// 新的输出泵会喂给它；只有处于失败态时才生效。
    func restart() {
        guard case .failed = state,
              let profile = lastProfile, let container = lastContainer, let relay = lastRelay else { return }
        teardownConnection()
        started = false
        state = .idle
        start(profile: profile, container: container, relay: relay)
    }

    /// 作废在途建连（代次 +1，晚到的结果一律丢弃），拆掉输出泵、输入通道与传输。
    private func teardownConnection() {
        connectGeneration &+= 1
        connectTask?.cancel()
        connectTask = nil
        outputPump.reset()
        exitTask?.cancel()
        reconnectTask?.cancel()
        reconnectTask = nil
        isReconnecting = false
        if let remote = connection as? RemoteTerminalBackend {
            remote.client.setProgramStatusWatched(remote.sessionID, false)
        }
        inputChannel.unbind()
        let conn = connection
        Task { await conn?.close() }
        connection = nil
    }

    deinit {
        if let ctrlResetObserver { NotificationCenter.default.removeObserver(ctrlResetObserver) }
        if let metaResetObserver { NotificationCenter.default.removeObserver(metaResetObserver) }
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
        if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
        // 输出泵与输入通道随控制器释放，各自的 deinit 收尾。
        exitTask?.cancel(); connectTask?.cancel()
    }
}

extension MobileTerminalController: ConnectionHealthProbing {
    func probeConnectionHealth() async {
        await state.probeHealth(of: connection)
    }
}
