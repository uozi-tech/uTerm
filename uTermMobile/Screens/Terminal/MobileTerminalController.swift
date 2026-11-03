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
    enum State: Equatable {
        case idle, connecting, connected, failed(String), closed
    }

    var state: State = .idle {
        // 离开「已连接」（失败 / 断开 / 重连中）就收起键盘：没有 shell 可打字，
        // 失败态的终端视图还会被失败页替换掉，留着键盘只会盖住失败页。
        didSet { if !canTakeKeyboard { resignKeyboard() } }
    }
    /// 本会话是不是此刻唯一该拿键盘的那个（聚焦格的前台标签、终端模式、上面没有连接中页 /
    /// 新建抽屉）。由工作区统一裁决、逐会话下发——每个标签只看自己的这一位。
    var ownsKeyboard = false {
        didSet { if !canTakeKeyboard { resignKeyboard() } }
    }
    /// 键盘只给真正进了终端、且轮到自己的会话：建连中 / 失败 / 已断开 / 不是键盘归属者一律不弹。
    /// 终端视图的 `canBecomeFirstResponder` 也读它，UIKit 自己恢复第一响应者（抽屉收起时）同样被拦。
    var canTakeKeyboard: Bool { state == .connected && ownsKeyboard }
    var title: String = ""
    /// 曾经连上过：用于把随后的 `.closed` 归为「成功收尾」而非「仍在连接」，
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
    /// 唯一的后端来源。默认 `.live` = 原来内联在 `start()` 里的真 SSH 组装。
    @ObservationIgnored private let transportFactory: MobileTerminalTransportFactory
    @ObservationIgnored private var outputTask: Task<Void, Never>?
    @ObservationIgnored private var outputFlushTask: Task<Void, Never>?
    @ObservationIgnored private let outputBuffer = TerminalOutputBuffer(capacityBytes: 4 * 1024 * 1024)
    @ObservationIgnored private var exitTask: Task<Void, Never>?
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    /// 建连代次：close() / restart() 递增，在途建连落地时对不上就丢弃结果。
    @ObservationIgnored private var connectGeneration = 0
    @ObservationIgnored private var inputContinuation: AsyncStream<TerminalInput>.Continuation?
    @ObservationIgnored private var inputTask: Task<Void, Never>?
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
            guard isForeground != oldValue, isForeground, outputFlushTask != nil else { return }
            startOutputFlushLoop(generation: outputGeneration)
        }
    }

    private var outputGeneration = 0

    /// 每拍喂给 SwiftTerm 的字节预算，随积压量放大。
    ///
    /// 固定预算时吞吐有硬上限（前台 32KB/16ms ≈ 2MB/s）：局域网里 `cat` 大文件超过它，
    /// 4MB 缓冲两秒就满，`TerminalOutputBuffer` 只能整块丢掉最旧的字节——会截断转义
    /// 序列，颜色 / 光标状态随之错乱。积压越多单拍喂得越多，丢字节只剩极端洪水一种情况；
    /// 平时（积压很小）仍是小块，单拍主线程开销不变。
    ///
    /// 后台旧方案是 250ms 一次喂 512KB，前台标签每 250ms 卡一下；现在拆成 64ms 一拍、
    /// 基础 128KB，吞吐不降，单次 feed 的主线程停顿小四倍。
    struct FlushPacing {
        let intervalMs: Int
        let baseBytes: Int
        let maxBytes: Int

        static let foreground = FlushPacing(intervalMs: 16, baseBytes: 32 * 1024, maxBytes: 256 * 1024)
        static let background = FlushPacing(intervalMs: 64, baseBytes: 128 * 1024, maxBytes: 512 * 1024)

        /// 积压的四分之一，夹在 [base, max] 之间：积压 1MB 时前台一拍 256KB。
        func budget(backlog: Int) -> Int {
            min(maxBytes, max(baseBytes, backlog / 4))
        }
    }
    // nonisolated(unsafe)：在 nonisolated deinit 里清理这两个非 Sendable 的观察者 token。
    // 仅在主线程设置、deinit（无其它引用存活）时读取，无并发访问。
    @ObservationIgnored private nonisolated(unsafe) var ctrlResetObserver: NSObjectProtocol?
    @ObservationIgnored private nonisolated(unsafe) var metaResetObserver: NSObjectProtocol?

    /// 记下首次建连参数，供失败后 `restart()` 在同一控制器 / 同一终端视图上重连。
    @ObservationIgnored private var lastProfile: ServerProfile?
    @ObservationIgnored private var lastContainer: ModelContainer?
    @ObservationIgnored private var lastRelay: HostKeyChallengeRelay?

    /// `transportFactory` 默认真 SSH——生产侧调用点（`TermTab`）不用改。
    init(transportFactory: MobileTerminalTransportFactory = .live) {
        self.transportFactory = transportFactory
    }

    func attach(_ view: SwiftTerm.TerminalView) {
        terminalView = view
        installModifierResetObserversIfNeeded()
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

    /// 切到该会话标签时让其终端重新成为第一响应者（弹回键盘）。未连上时不弹。
    func focusKeyboard() {
        guard canTakeKeyboard else { return }
        _ = terminalView?.becomeFirstResponder()
    }

    /// 用一台主机建连并开 PTY。重复调用无副作用（已建连过则忽略）。
    /// `relay` 把首次连接 / 密钥变化的 host-key 挑战交给用户裁决（替代盲信 TOFU）。
    func start(profile: ServerProfile, container: ModelContainer, relay: HostKeyChallengeRelay) {
        guard !started else { return }
        started = true
        title = profile.name
        state = .connecting
        lastProfile = profile; lastContainer = container; lastRelay = relay
        connectGeneration &+= 1
        let attempt = connectGeneration
        let pid = profile.persistentModelID
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
            state = .failed("认证材料解析失败：\(error.localizedDescription)")
            return nil
        }
    }

    /// 握手结果落地。握手期间被关闭 / 被重连取代时不能把 `.closed` 翻回 `.connected`。
    private func finishConnect(_ error: (any Error)?, attempt: Int,
                               pid: PersistentIdentifier, container: ModelContainer) {
        guard connectGeneration == attempt else { return }
        if let error {
            state = .failed(error.localizedDescription)
            return
        }
        state = .connected
        hadConnected = true
        // 回前台 / 换网络 / 每 30s 探一次活：后台挂久了的半死 TCP 不会自己报错，
        // 标签一直显示「已连接」、输入只进内核缓冲。判死后走 exitStream → `.closed`。
        ConnectionWatchdog.shared.register(self)
        if let profile = container.mainContext.model(for: pid) as? ServerProfile {
            profile.lastConnectedAt = Date()
            try? container.mainContext.save()
        }
    }

    /// 接上一条刚造好的传输：输出泵、退出监听、有序的输入通道。
    private func install(_ conn: any TerminalBackend) {
        connection = conn
        let outStream = conn.outputStream
        let exitStream = conn.exitStream
        resetOutputPipeline()
        let generation = outputGeneration
        let buffer = outputBuffer

        // SSH 入站不再每个 chunk 都 hop MainActor；先进入有界缓冲，再按帧合并 feed。
        outputTask = Task.detached(priority: .userInitiated) {
            for await chunk in outStream {
                if Task.isCancelled { break }
                buffer.append(chunk, generation: generation)
            }
        }
        startOutputFlushLoop(generation: generation)
        exitTask = Task { [weak self] in
            for await _ in exitStream {
                if case .failed = self?.state { } else { self?.state = .closed }
                break
            }
        }

        // 击键 / 尺寸变化走同一条 FIFO：每次各起一个 Task 时，两个 Task 谁先进
        // 后端 actor 没有语言层面的保证，快速连打可能乱序。
        let (inputs, continuation) = AsyncStream.makeStream(of: TerminalInput.self)
        inputContinuation = continuation
        inputTask = Task {
            for await input in inputs {
                switch input {
                case .data(let data): await conn.write(data)
                case .resize(let cols, let rows): await conn.resize(cols: cols, rows: rows)
                }
            }
        }
    }

    func write(_ data: Data) {
        inputContinuation?.yield(.data(data))
    }

    func sendText(_ text: String) {
        write(Data(text.utf8))
    }

    func resize(cols: UInt16, rows: UInt16) {
        inputContinuation?.yield(.resize(cols: cols, rows: rows))
    }

    func close() {
        teardownConnection()
        state = .closed
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
        resetOutputPipeline()
        exitTask?.cancel()
        inputContinuation?.finish()
        inputContinuation = nil
        inputTask = nil
        let conn = connection
        Task { await conn?.close() }
        connection = nil
    }

    private func resetOutputPipeline() {
        outputGeneration &+= 1
        outputTask?.cancel()
        outputTask = nil
        outputFlushTask?.cancel()
        outputFlushTask = nil
        outputBuffer.clear()
    }

    private func startOutputFlushLoop(generation: Int) {
        outputFlushTask?.cancel()
        let buffer = outputBuffer
        outputFlushTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.outputGeneration == generation else { return }
                guard let terminalView = self.terminalView else {
                    // attach 通常早于 start；若视图尚未挂上，保留 buffer 并低频重试。
                    try? await Task.sleep(for: .milliseconds(FlushPacing.foreground.intervalMs))
                    continue
                }

                let pacing: FlushPacing = self.isForeground ? .foreground : .background
                let chunk = buffer.drain(
                    maxBytes: pacing.budget(backlog: buffer.pendingBytes),
                    generation: generation)
                if chunk.isEmpty {
                    await buffer.waitForData()
                } else {
                    terminalView.feed(byteArray: ArraySlice([UInt8](chunk)))
                    try? await Task.sleep(for: .milliseconds(pacing.intervalMs))
                }
            }
        }
    }

    deinit {
        if let ctrlResetObserver { NotificationCenter.default.removeObserver(ctrlResetObserver) }
        if let metaResetObserver { NotificationCenter.default.removeObserver(metaResetObserver) }
        outputTask?.cancel(); outputFlushTask?.cancel(); exitTask?.cancel(); connectTask?.cancel()
        inputContinuation?.finish()
        outputBuffer.clear()
    }
}

/// 发往后端的输入，按产生顺序排队。
private enum TerminalInput: Sendable {
    case data(Data)
    case resize(cols: UInt16, rows: UInt16)
}

extension MobileTerminalController: ConnectionHealthProbing {
    func probeConnectionHealth() async {
        guard state == .connected, let connection else { return }
        _ = await connection.verifyConnectionAlive()
    }
}
