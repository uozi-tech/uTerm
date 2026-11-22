import AppKit
import Observation
import SwiftUI
import UDesignKit

/// 远程 Mac 屏幕窗口的身份：一台 Mac 最多一个（同一个值再开会带出已有的那个）。
nonisolated struct RemoteDesktopWindowID: Codable, Hashable, Sendable {
    /// `RemoteMacDirectory.Mac.id`。
    let macID: String
}

/// 屏幕窗口的状态：连那台 Mac（与它的终端窗口共用一条连接），连上后开一路画面。
@MainActor
@Observable
final class RemoteDesktopWindowModel {
    let client: RemoteMacClient
    let session: RemoteDesktopSession
    @ObservationIgnored private var closed = false

    init(client: RemoteMacClient, session: RemoteDesktopSession? = nil) {
        self.client = client
        let size = Self.requestedPixels()
        self.session = session ?? RemoteDesktopSession(client: client, maxWidth: size.width, maxHeight: size.height,
                                                       pointScale: size.scale, cursorImages: true)
    }

    /// 连上（第一次时在那台 Mac 上核对配对数字），再开流。已经在放就什么也不做。
    func start() async {
        closed = false
        await client.connect()
        await startStreamIfConnected()
    }

    /// 连接状态变了（核对完配对、断线重连上）：还没在放就开流。
    func startStreamIfConnected() async {
        guard !closed, client.state == .connected else { return }
        switch session.state {
        case .idle, .failed, .ended: await session.start()
        case .connecting, .streaming, .reconnecting, .unsupported: break
        }
    }

    /// 关窗口：停掉这一路画面（那台 Mac 停止采集，帘幕随之撤掉）。连接由目录按窗口计数决定断不断。
    func close() {
        closed = true
        session.stop()
    }

    /// 要多大的画面：按本机最大那块屏幕的像素（见 `RemoteDesktopSession.requestedSize`）。那台 Mac 会按自己
    /// 显示器的比例套进这个框里；它没接显示器时按这些像素除以 `scale` 的点数建虚拟屏（和这块屏一样大）。
    /// `scale` 取像素最多的那块屏的。
    static func requestedPixels(screens: [NSScreen] = NSScreen.screens) -> (width: Int, height: Int, scale: Double) {
        requestedPixels(screens: screens.map { (size: $0.frame.size, scale: $0.backingScaleFactor) })
    }

    static func requestedPixels(screens: [(size: CGSize, scale: CGFloat)]) -> (width: Int, height: Int, scale: Double) {
        var long = 0, short = 0, scale = 2.0
        for screen in screens {
            let w = Int(screen.size.width * screen.scale), h = Int(screen.size.height * screen.scale)
            if max(w, h) > long { scale = Double(screen.scale) }
            long = max(long, max(w, h))
            short = max(short, min(w, h))
        }
        let size = RemoteDesktopSession.requestedSize(longPixels: long, shortPixels: short)
        return (size.width, size.height, scale)
    }
}

/// 一台远程 Mac 的屏幕窗口：整窗黑底，顶上一条细栏（居中是名字与状态点，右边是声音、读数、帘幕、全屏），
/// 下面全是画面，和手机上的远程桌面一样。画面上按状态盖遮罩（连接中 / 核对配对 / 失败 / 锁屏…）。
struct RemoteDesktopWindowView: View {
    let windowID: RemoteDesktopWindowID?

    @Environment(RemoteMacDirectory.self) private var directory
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var model: RemoteDesktopWindowModel?
    @State private var missing = false

    var body: some View {
        Group {
            if let model {
                RemoteDesktopContent(model: model, onDiagnose: windowID.map { id in
                    { openWindow(value: RemoteDiagnosticsWindowID(macID: id.macID)) }
                })
            } else {
                VStack(spacing: 0) {
                    RemoteDesktopTitleBar { Text(missing ? "找不到这台 Mac" : "").foregroundStyle(.white.opacity(0.9)) }
                    Color.black.overlay {
                        if missing {
                            Text("它可能已被忘记。在「我的 Mac」里重新配对。")
                                .font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.7))
                        }
                    }
                }
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
        .background(WorkspaceWindowChrome(serverName: "", background: .black))
        .background(WindowTitleBinding(title: model.map { String(localized: "\($0.client.macName) 的屏幕") }
            ?? String(localized: "屏幕")))
        // ⌘W 关这扇窗口，不发给那台 Mac（本机窗口的监听比画布先拿到按键）。
        .background(WorkspaceCloseShortcutInstaller { window in window.performClose(nil) })
        .frame(minWidth: 640, minHeight: 420)
        .task { await start() }
        .onDisappear {
            guard let model else { return }
            model.close()
            if let windowID { directory.releaseClient(macID: windowID.macID) }
        }
    }

    private func start() async {
        guard let windowID else {
            dismiss()
            return
        }
        guard model == nil else { return }
        if !directory.isActivated { directory.activate() }
        guard let mac = directory.mac(id: windowID.macID) else {
            missing = true
            return
        }
        let model = RemoteDesktopWindowModel(client: directory.acquireClient(for: mac))
        self.model = model
        await model.start()
    }
}

/// 窗口顶上那条栏：黑底、可拖动窗口。标题居中（和别的窗口一样），按钮靠右，左边让出红绿灯。
private struct RemoteDesktopTitleBar<Title: View, Trailing: View>: View {
    @ViewBuilder var title: () -> Title
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        ZStack {
            title()
                .padding(.horizontal, 120)
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                trailing()
            }
            .padding(.trailing, 10)
        }
        .frame(height: 38)
        .frame(maxWidth: .infinity)
        .background(WindowDragHandle(fill: .black))
    }
}

extension RemoteDesktopTitleBar where Trailing == EmptyView {
    init(@ViewBuilder title: @escaping () -> Title) {
        self.init(title: title) { EmptyView() }
    }
}

struct RemoteDesktopContent: View {
    @Bindable var model: RemoteDesktopWindowModel
    /// 连不上时给的「网络诊断」入口；nil 不显示。
    var onDiagnose: (() -> Void)?

    @State private var note: String?
    @State private var noteTask: Task<Void, Never>?
    @State private var showStats = false
    @AppStorage(DefaultsKey.remoteDesktopSendSystemShortcuts) private var sendSystemShortcuts = true
    @State private var password = ""
    @State private var unlocking = false
    @State private var unlockError: String?
    /// 替那台 Mac 的验证框填的密码（不保存）、在途、失败原因。
    @State private var authPassword = ""
    @State private var authWorking = false
    @State private var authError: String?
    /// 「只看一个窗口」的弹层和它的内容。
    @State private var pickingWindow = false
    @State private var windowChoices: [RemoteDesktopWindowSummary] = []
    @State private var windowNote: String?
    @State private var loadingWindows = false
    /// 放大镜：点一下换一档（画布自己记倍数，这里只留着给按钮高亮）。
    @State private var zoomStepToken = 0
    @State private var zoomLevel: CGFloat = 1

    private var session: RemoteDesktopSession { model.session }
    private var client: RemoteMacClient { model.client }

    var body: some View {
        VStack(spacing: 0) {
            RemoteDesktopTitleBar { title } trailing: { buttons }
            ZStack {
                RemoteDesktopMacCanvas(
                    session: session,
                    displaySize: session.info.map { CGSize(width: $0.displayWidth, height: $0.displayHeight) },
                    contentFraction: session.contentFraction,
                    onPasteNote: { show($0) },
                    sendSystemShortcuts: sendSystemShortcuts,
                    onShortcutCaptureFailed: {
                        show(String(localized: "在「系统设置 › 隐私与安全性 › 辅助功能」里允许 uTerm，才能把 ⌘Tab 等系统快捷键发过去"),
                             seconds: 6)
                    },
                    zoomStepToken: zoomStepToken,
                    onZoomChanged: { zoomLevel = $0 })
                stateOverlay
                lockOverlay
                authPromptOverlay
            }
            .overlay(alignment: .top) { toast }
            .overlay(alignment: .topLeading) { statsBadge }
        }
        .onAppear {
            session.onClipboard = { content in show(RemoteDesktopMacPasteSource.receive(content)) }
        }
        .onChange(of: client.state) { _, _ in Task { await model.startStreamIfConnected() } }
        .onChange(of: session.audioState) { _, state in
            // 那台 Mac 上没开、采集停了、本机输出设备没了：按钮已经复位，这里说一声为什么。
            if case .unavailable(let reason) = state { show(reason, seconds: 4) }
        }
    }

    // MARK: - 顶栏

    /// 居中：状态点 + 名字；不是正常可控时在名字后面跟一句状态。
    private var title: some View {
        HStack(spacing: 7) {
            Circle().fill(statusDot).frame(width: 7, height: 7)
            Text(client.macName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
            if let statusText {
                Text(statusText)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
        }
        .allowsHitTesting(false)
    }

    private var buttons: some View {
        HStack(spacing: 4) {
            if session.state == .streaming {
                if let displays = session.info?.displays, displays.count > 1 {
                    displayMenu(displays)
                }
                if session.supportsWindows {
                    barButton("macwindow", active: session.windowID != nil,
                              help: session.windowID != nil ? String(localized: "窗口模式（点按换一个窗口，或回到整个屏幕）")
                                                            : String(localized: "窗口模式")) {
                        pickingWindow = true
                    }
                    .popover(isPresented: $pickingWindow, arrowEdge: .bottom) { windowPicker }
                }
                if session.canControl {
                    barButton("command", active: sendSystemShortcuts,
                              help: sendSystemShortcuts
                                ? String(localized: "正在把 ⌘Tab、⌘空格、⌘W 等快捷键发给那台 Mac（点按改为留在本机）")
                                : String(localized: "⌘Tab、⌘空格、⌘W 等快捷键留在本机（点按改为发给那台 Mac）")) {
                        sendSystemShortcuts.toggle()
                    }
                }
                if session.supportsAudio {
                    barButton(session.isAudioOn ? "speaker.wave.2.fill" : "speaker.slash", active: session.isAudioOn,
                              help: session.isAudioOn ? String(localized: "关闭声音")
                                                      : String(localized: "打开声音：在本机播放那台 Mac 的声音")) {
                        session.toggleAudio()
                    }
                }
                barButton(zoomLevel > 1 ? "minus.magnifyingglass" : "plus.magnifyingglass", active: zoomLevel > 1,
                          help: zoomLevel > 1
                            ? String(localized: "已放大，画面跟着指针走（点按换下一档；触控板上双指捏合也可以）")
                            : String(localized: "放大画面：画面跟着指针走（触控板上双指捏合也可以）")) {
                    zoomStepToken += 1
                }
                barButton("gauge.with.dots.needle.33percent", active: showStats,
                          help: showStats ? String(localized: "隐藏延迟与帧率") : String(localized: "显示延迟与帧率")) {
                    showStats.toggle()
                }
                if session.screen.canToggleCurtain(supportsUnlock: session.supportsUnlock) {
                    barButton(session.screen.curtained ? "eye.slash.fill" : "eye.slash",
                              active: session.screen.curtained,
                              help: session.screen.curtained ? String(localized: "关闭帘幕：那台 Mac 的屏幕恢复显示")
                                                             : String(localized: "帘幕：那台 Mac 的屏幕变黑，本机键鼠暂停")) {
                        session.setCurtain(!session.screen.curtained)
                    }
                }
            }
            barButton("arrow.up.left.and.arrow.down.right", active: false, help: String(localized: "全屏")) {
                NSApp.keyWindow?.toggleFullScreen(nil)
            }
        }
    }

    /// 那台 Mac 接着几块显示器时：选看哪一块（重开这路画面）。
    private func displayMenu(_ displays: [RemoteDesktopDisplaySummary]) -> some View {
        Menu {
            ForEach(displays, id: \.id) { display in
                Button {
                    Task { await session.switchDisplay(to: display.id) }
                } label: {
                    if display.id == session.info?.displayID {
                        Label(display.menuTitle, systemImage: "checkmark")
                    } else {
                        Text(display.menuTitle)
                    }
                }
            }
        } label: {
            Image(systemName: "display.2")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(String(localized: "切换显示器"))
        .accessibilityLabel(Text("切换显示器"))
    }

    /// 选「只看哪一个窗口」：打开时向那台 Mac 要一次列表。选中后重开这路画面，那台 Mac 会先把窗口提到最前。
    private var windowPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            windowRow(title: String(localized: "整个屏幕"), detail: nil, selected: session.windowID == nil) { chooseWindow(nil) }
            Divider().padding(.vertical, 4)
            if loadingWindows, windowChoices.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在读取窗口…").font(UD.font(12)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(windowChoices, id: \.id) { window in
                        windowRow(title: window.menuTitle, detail: window.menuDetail,
                                  selected: session.windowID == window.id) { chooseWindow(window.id) }
                    }
                }
            }
            .frame(maxHeight: 360)
            if let windowNote {
                Text(verbatim: windowNote).font(UD.font(11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10).padding(.vertical, 8)
            } else if !loadingWindows, windowChoices.isEmpty {
                Text("那台 Mac 上此刻没有可以单独看的窗口。").font(UD.font(11.5)).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 8)
            }
        }
        .padding(6)
        .frame(width: 320)
        .task { await loadWindows() }
    }

    private func windowRow(title: String, detail: String?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark").font(.system(size: 10.5, weight: .semibold)).opacity(selected ? 1 : 0)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: title).font(UD.font(12.5)).lineLimit(1)
                    if let detail {
                        Text(verbatim: detail).font(UD.font(11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.udPlain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func chooseWindow(_ id: UInt32?) {
        pickingWindow = false
        Task { await session.switchWindow(to: id) }
    }

    private func loadWindows() async {
        loadingWindows = true
        defer { loadingWindows = false }
        do {
            let list = try await client.desktopWindows()
            windowChoices = list.windows
            windowNote = list.message
        } catch {
            windowNote = error.localizedDescription
        }
    }

    /// 读数：盖在画面左上角，点顶栏的仪表按钮开关。
    @ViewBuilder private var statsBadge: some View {
        if showStats, session.state == .streaming {
            let items = session.statItems
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                ForEach(items) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(item.label)
                            .font(UD.font(10.5))
                            .foregroundStyle(.white.opacity(0.55))
                        Text(item.value)
                            .font(UD.mono(11, weight: .medium))
                            .foregroundStyle(Self.statColor(item.level))
                        Text(item.unit)
                            .font(UD.mono(10))
                            .foregroundStyle(.white.opacity(0.55))
                        if let detail = item.detail {
                            Text(detail)
                                .font(UD.mono(10))
                                .foregroundStyle(.white.opacity(0.4))
                                .padding(.leading, 2)
                        }
                    }
                }
            }
            .lineLimit(1)
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(RemoteDesktopStat.spokenText(items))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(.black.opacity(0.6)))
            .padding(10)
            .allowsHitTesting(false)
        }
    }

    private static func statColor(_ level: RemoteDesktopStat.Level) -> Color {
        switch level {
        case .normal: return .white.opacity(0.92)
        case .warning: return UD.warning
        case .poor: return UD.danger
        }
    }

    private var statusDot: Color {
        if case .awaitingApproval = client.state { return UD.warning }
        switch session.state {
        case .streaming: return session.canControl ? UD.success : UD.warning
        case .idle, .connecting, .reconnecting: return .white.opacity(0.35)
        case .failed, .ended, .unsupported: return UD.danger
        }
    }

    /// 正常可控时不写字（绿点就够了）。
    private var statusText: String? {
        switch client.state {
        case .connecting where session.state != .streaming: return String(localized: "正在连接…")
        case .awaitingApproval: return String(localized: "等待那台 Mac 确认配对")
        default: break
        }
        return session.statusText(controlling: nil)
    }

    private func barButton(_ symbol: String, active: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(active ? .white : .white.opacity(0.6))
                .frame(width: 28, height: 24)
                .background(Color.white.opacity(active ? 0.16 : 0), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.udPlain)
        .help(help)
        .accessibilityLabel(Text(help))
    }

    // MARK: - 遮罩

    @ViewBuilder private var stateOverlay: some View {
        if case .awaitingApproval(let code) = client.state {
            RemoteMacPairingCodeView(macName: client.macName, code: code).background(Color.black)
        } else if case .failed(let message) = client.state, session.state != .streaming {
            notice(spinner: false, title: String(localized: "无法连接 \(client.macName)"), message: message) {
                HStack(spacing: 8) {
                    UDButton(title: String(localized: "重试")) { Task { await model.start() } }
                    if let onDiagnose {
                        UDButton(title: String(localized: "网络诊断"), style: .secondary, action: onDiagnose)
                    }
                }
            }
        } else {
            sessionOverlay
        }
    }

    @ViewBuilder private var sessionOverlay: some View {
        if let notice = session.notice(macName: client.macName, showsClose: false) {
            self.notice(spinner: notice.spinner, title: notice.title, message: notice.message, dim: notice.dim) {
                ForEach(Array(notice.actions.enumerated()), id: \.offset) { index, action in
                    UDButton(title: action.title, style: index == 0 ? .primary : .secondary) { perform(action) }
                }
            }
        } else if let caption = session.controlCaption {
            bottomCaption(caption)
        }
    }

    private func perform(_ action: RemoteDesktopNotice.Action) {
        switch action {
        case .retry: Task { await session.start() }
        // 流结束了：先把连接接上（可能已经断了），再开流。
        case .reconnect: Task { await model.start() }
        case .close: NSApp.keyWindow?.performClose(nil)
        }
    }

    /// 底部一句说明，不挡画面、不接鼠标。
    private func bottomCaption(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Capsule().fill(.black.opacity(0.6)))
                .padding(.bottom, 20).padding(.horizontal, 20)
        }
        .allowsHitTesting(false)
    }

    /// 那台 Mac 停在锁屏：在这里输登录密码解锁（不保存）。解锁后那台 Mac 进入帘幕，锁屏状态由它推来，这层自然消失。
    /// 什么时候显示见 `lockPrompt`；没开远程解锁时只在底部提示一句，不挡画面（仍可直接在锁屏上输密码）。
    @ViewBuilder private var lockOverlay: some View {
        switch session.lockPrompt(macName: client.macName) {
        case .none:
            EmptyView()
        case .caption(let text):
            bottomCaption(text)
        case .unlock:
            notice(spinner: unlocking, title: String(localized: "\(client.macName) 已锁定"),
                   message: unlockError ?? String(localized: "输入那台 Mac 的登录密码。解锁后它的屏幕会变黑并暂停本机键鼠，密码不会保存。")) {
                if !unlocking {
                    HStack(spacing: 8) {
                        UDTextField(placeholder: String(localized: "登录密码"), text: $password, autoFocus: true,
                                    isSecure: true)
                            .frame(width: 220)
                            .onSubmit { submitUnlock() }
                        UDButton(title: String(localized: "解锁", comment: "按钮：解锁那台 Mac")) { submitUnlock() }
                            .disabled(password.isEmpty)
                    }
                }
            }
        }
    }

    /// 那台 Mac 屏上有要 Touch ID / 密码的系统框：在这里填它的登录密码（不保存），或取消那个请求。
    /// 不盖住画面，只在底部放一张卡片：框本身还要看得见。什么时候显示见 `authPromptBanner`。
    @ViewBuilder private var authPromptOverlay: some View {
        switch session.authPromptBanner(macName: client.macName) {
        case .none:
            EmptyView()
        case .caption(let text):
            bottomCaption(text)
        case .actionable(let prompt, let title, let message):
            VStack {
                Spacer()
                VStack(spacing: 10) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(authError ?? message)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                    if authWorking {
                        UDIndeterminateBar().frame(width: 140)
                    } else {
                        HStack(spacing: 8) {
                            UDTextField(placeholder: String(localized: "登录密码"), text: $authPassword, isSecure: true)
                                .frame(width: 200)
                                .onSubmit { answerAuthPrompt(prompt, action: .fill) }
                            UDButton(title: String(localized: "填入密码")) { answerAuthPrompt(prompt, action: .fill) }
                                .disabled(authPassword.isEmpty)
                            UDButton(title: String(localized: "取消请求"), style: .secondary) { answerAuthPrompt(prompt, action: .cancel) }
                        }
                    }
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 12).fill(.black.opacity(0.8)))
                .padding(.bottom, 24).padding(.horizontal, 20)
            }
            .onChange(of: prompt.id) { _, _ in authError = nil }
        }
    }

    private func answerAuthPrompt(_ prompt: RemoteDesktopAuthPrompt, action: RemoteDesktopAuthPromptRequest.Action) {
        guard !authWorking, action == .cancel || !authPassword.isEmpty else { return }
        let secret = action == .fill ? authPassword : nil
        authPassword = ""
        authWorking = true
        authError = nil
        Task {
            let outcome = await session.answerAuthPrompt(prompt, action: action, password: secret)
            authWorking = false
            authError = outcome.failureMessage
        }
    }

    private func submitUnlock() {
        guard !password.isEmpty, !unlocking else { return }
        let secret = password
        password = ""
        unlocking = true
        unlockError = nil
        Task {
            let outcome = await session.unlock(password: secret)
            unlocking = false
            unlockError = outcome.failureMessage
        }
    }

    private func notice(spinner: Bool, title: String, message: String?, dim: Bool = false) -> some View {
        notice(spinner: spinner, title: title, message: message, dim: dim) { EmptyView() }
    }

    private func notice<Buttons: View>(spinner: Bool, title: String, message: String?, dim: Bool = false,
                                       @ViewBuilder buttons: () -> Buttons) -> some View {
        ZStack {
            Color.black.opacity(dim ? 0.45 : 0.75)
            VStack(spacing: 12) {
                if spinner { UDIndeterminateBar().frame(width: 140) }
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                if let message, !message.isEmpty {
                    Text(message)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
                HStack(spacing: 10) { buttons() }
                    .padding(.top, 4)
            }
            .padding(24)
        }
    }

    // MARK: - 提示

    @ViewBuilder private var toast: some View {
        if let note {
            Text(note)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(Capsule().fill(.black.opacity(0.75)))
                .padding(.top, 10)
                .transition(.opacity)
                .allowsHitTesting(false)
        }
    }

    private func show(_ text: String, seconds: Double = 2.5) {
        noteTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) { note = text }
        noteTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.2)) { note = nil }
        }
    }
}
