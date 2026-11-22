import UDesignKit
import SwiftUI
import SwiftData
import Observation
import UIKit

/// 连接目标：终端会话 / SFTP 文件浏览（设计稿 `m-connect` 的 `kind`）。
enum MConnectKind: Hashable { case terminal, sftp }

/// 连接中页据以推进的统一阶段：连接中 / 已连接 / 失败（带错误文案）。
/// 由目标屏绑定的真实控制器状态映射而来（事件驱动，见 `MConnectRequest.phase`）。
enum MConnPhase: Equatable { case connecting, connected, failed(String) }

/// 一次「受保护连接」的请求：在选定主机与会话/文件浏览打开之间，根视图据此呈现全屏
/// 「连接中」中转页（设计稿 `m-shell` 的 `cover.type === 'connecting'`）。
///
/// 连接本体仍跑在目标屏（终端 / 文件）里——终端必须在建连期就把 `MTerminalHostView` 挂上，
/// 否则 shell 首屏（prompt / MOTD）字节会丢。目标屏在建连后把运行时控制器回填到本请求，
/// 连接中页据其 `state` 真实推进阶段并在 `.connected` 时收尾。
@MainActor
@Observable
final class MConnectRequest: Identifiable {
    let id = UUID()
    let host: ServerProfile
    let kind: MConnectKind
    /// 来源标签：长按取消 / 失败返回时回到此处。
    let origin: MTab

    /// 绑定的运行时控制器（目标屏回填）；连接中页观察其 `state` 推进。
    var terminal: MobileTerminalController?
    var sftp: MobileSFTPController?
    /// 工作区会话标签 id：取消时定位要移除的标签。
    var tabID: UUID?
    /// 接管 Mac 时跟 `tabID` 一起新开的其余标签：取消时一并关掉，不留没人看的接管。
    var companionTabIDs: [UUID] = []
    /// 发起时工作区是否已展开（工作区里「+」新建）：取消后回到工作区，而不是收回主机列表。
    var originInWorkspace = false
    /// 强制新开会话（终端「+」新建：即便已有同主机会话也再开一个）。
    var allowDuplicate = false
    /// 连接尝试代次：重试时自增，驱动连接中页重跑阶段动画。
    var attempt = 0
    /// 远控：经 Mac 接入它上面的终端。连接中页据此换掉 SSH 专属的文案。
    var remote: MRemoteSource?

    /// 连接中页是否只盖工作区里那个标签：分屏状态下、从工作区里发起（「+」/ 空格）的才是。
    /// 工作区收起时（建连途中点了「返回」）改回整屏：否则格内那张连接中页随工作区藏到屏外，
    /// 主机列表上点什么都被 `requestConnect` 静默吞掉，用户却看不到为什么。
    func showsInPane(_ workspace: MobileWorkspace, workspaceVisible: Bool) -> Bool {
        originInWorkspace && workspace.isSplit && workspaceVisible
    }

    init(host: ServerProfile, kind: MConnectKind, origin: MTab) {
        self.host = host
        self.kind = kind
        self.origin = origin
    }

    /// 把目标屏控制器的真实状态收敛成连接中页的三态。控制器未绑定前一律视作连接中。
    var phase: MConnPhase {
        if let t = terminal {
            switch t.state {
            case .connected: return .connected
            case .failed(let m): return .failed(m)
            // 连上后立刻断开（服务器关闭 / 网络抖动）：Observation 可能把 .connected 与 .disconnected
            // 合并到同一 tick，使连接中页观测不到 .connected。若曾连上过，把 .disconnected 也判为成功
            // 收尾（露出会话，由会话自身展示断开态），避免中转页卡死。
            case .disconnected: return t.hadConnected ? .connected : .connecting
            case .idle, .connecting: return .connecting
            }
        }
        if let s = sftp {
            switch s.state {
            case .connected: return .connected
            case .failed(let m): return .failed(m)
            case .idle, .connecting: return .connecting
            }
        }
        return .connecting
    }

    /// 失败后在同一控制器 / 同一终端视图上重连（连接中页「重试」）。
    func restart() {
        attempt += 1
        switch kind {
        case .terminal: terminal?.restart()
        case .sftp: sftp?.restart()
        }
    }
}

// MARK: - 连接中页（设计稿 m-connect `ConnectingCover`）

/// 全屏「连接中」中转页。整页垂直三段：顶部胶囊 chip / 中部进度环与主机信息 / 底部失败操作或「返回」。
/// 唯一动效是进度环的匀速旋转。
///
/// 节奏按「别让人等动画」来：底色一出现就挡住误触，内容晚 `revealDelay` 才露面——这之前就连上的
///（同主机复用连接约 60ms）直接进会话、不演成功态；露面后连上的只停 `successHold` 让对勾被看见。
struct ConnectingCoverView: View {
    let request: MConnectRequest
    /// 已连接、成功态停留片刻后撤下中转页、露出会话。
    var onFinish: () -> Void
    /// 长按取消 / 失败返回：关闭半开会话并回到来源页。
    var onCancel: () -> Void
    /// 失败后重试：同一控制器重连。
    var onRetry: () -> Void
    /// 盖满整屏（从主机列表进来）还是只盖一个分屏格里的标签区（分屏时在工作区里新开标签）。
    /// 格内不碰状态栏 / 屏幕居中那套，按格裁切；格太矮时收起阶段卡片。
    var fillsScreen = true

    @Environment(\.mAccent) private var accent
    @Environment(\.mChrome) private var chrome
    @State private var height: CGFloat = 0
    /// 格内且高度不够完整排版（进度环 + 名字 + 底部区约 420pt）：收紧上下留白、底部区不占固定高度。
    private var compact: Bool { !fillsScreen && height > 0 && height < 420 }
    /// 已连接即闩锁（提交成功）：避免「连上即被服务器立刻断开」把状态翻回连接中导致卡死；
    /// 同时一旦提交即隐藏取消按钮，规避「已连上又被取消」竞态。
    @State private var finishing = false
    /// 内容（chip / 进度环 / 文案）是否已露面。露面前只有底色，见类型注释。
    @State private var revealed = false
    /// 连接耗时过长（~5s 仍未成功/失败）后露出「返回」逃生口：快速连接不显示，
    /// 保留「不可中途打断」的设计意图；卡在某一握手阶段（如认证）时给用户退路。
    @State private var canCancel = false

    private var isSftp: Bool { request.kind == .sftp }
    private var host: ServerProfile { request.host }
    private var phase: MConnPhase { request.phase }
    /// 原始已连接信号（用于闩锁触发）。
    private var connectedNow: Bool { phase == .connected }
    /// 显示用成功态：内容露面后才连上的才演（露面前连上的直接进会话）。
    private var success: Bool { finishing && revealed }
    private var failureMessage: String? {
        if finishing { return nil }   // 已提交成功：不再显示失败
        if case .failed(let m) = phase { return m }
        return nil
    }
    private var ringMode: ConnRing.Mode {
        if success { return .success }
        if failureMessage != nil { return .failed }
        return .connecting
    }

    /// 顶部 chip 放进状态栏那一行时的行高（Duo 展开竖屏：状态栏只占顶行右端）。
    /// chip 水平居中，右缘碰到状态栏（或系统给的顶部横条区域右界）就不进，照旧排在安全区下面。
    ///
    /// Duo 内屏分屏（窗口约 330pt）放不下居中的 chip，只认窗口够宽（≥ 600pt，展开整屏 669）的情形。
    private var chipStatusRow: CGFloat? { Self.chipStatusRow(chrome: chrome, fillsScreen: fillsScreen) }

    static func chipStatusRow(chrome: MChromeGeometry, fillsScreen: Bool) -> CGFloat? {
        guard fillsScreen, let row = chrome.statusRowHeight,
              chrome.screen.width >= statusRowMinScreenWidth else { return nil }
        let limit = chrome.topBar?.maxX ?? chrome.statusBar?.minX ?? .infinity
        return chrome.screen.midX + chipHalfWidth + 8 <= limit ? row : nil
    }

    private static let statusRowMinScreenWidth: CGFloat = 600

    /// chip 半宽的保守估计（「SFTP 文件」/「终端会话」两种文案，实测约 110pt 宽）。
    private static let chipHalfWidth: CGFloat = 64

    /// 内容露面前的等待：短于它的连接（复用连接）整页只闪一下底色。
    static let revealDelay: Duration = .milliseconds(150)
    /// 成功对勾的停留：够看清转绿，又不让人干等。
    static let successHold: Duration = .milliseconds(250)

    var body: some View {
        let statusRow = chipStatusRow
        ZStack {
            M.canvas.ignoresSafeArea()
            VStack(spacing: 0) {
                if let statusRow {
                    // 与状态栏同一行、行内竖直居中（对齐时间 / 电量的中线）。
                    topChip.frame(height: statusRow)
                } else if !fillsScreen {
                    // 格内：上面就是标签条，不需要顶边净空。
                    topChip.padding(.top, compact ? 10 : 16)
                } else {
                    // 状态栏不在顶边时（iPhone Duo 折叠 / 横屏）chip 别贴着屏幕顶。
                    topChip.mTopClearance()
                }
                Spacer(minLength: 8)
                centerStack
                Spacer(minLength: 8)
                // 底部区固定高度：连接 / 成功 / 失败三态高度一致，切换时中部进度环不位移。
                bottomArea
                    .frame(maxWidth: .infinity, minHeight: compact ? 0 : 112, alignment: .bottom)
                    .padding(.horizontal, 24)
                    .padding(.bottom, compact ? 14 : 30)
            }
            .opacity(revealed || failureMessage != nil ? 1 : 0)
            // Duo 展开竖屏：整条顶行都算安全区，chip 伸进去与状态栏同行（见 chipStatusRow）。
            .ignoresSafeArea(.container, edges: statusRow != nil ? .top : [])
            // 中转页对软键盘免疫：底层会话即便弹出键盘也不会顶起本页布局（防动画错乱）。
            .ignoresSafeArea(.keyboard, edges: .bottom)
            // Duo 状态栏在右侧一列时按整块屏幕居中，而不是按去掉那一列的宽度（看起来偏左）。
            .modifier(CoverScreenCentering(enabled: fillsScreen))
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        // 只在格内裁切（底色别溢出那一格）。整屏时不能裁：底色要铺进状态栏 / Home 条 /
        // Duo 侧边那一列等安全区，一裁就露出底下的界面、看上去没盖满整屏。
        .modifier(CoverPaneClip(enabled: !fillsScreen))
        .contentShape(Rectangle())   // 不透明全屏：吸收所有落到下层导航的误触
        // 出现即收起任何残留键盘（来源页 / 上一个终端会话的键盘），避免盖在中转页上。
        .onAppear {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                            to: nil, from: nil, for: nil)
        }
        // 中转页在场期间，下层终端只要又拿到第一响应者（UIKit 回切标签时恢复响应者等），
        // 键盘就会盖在中转页上，而本页没有任何输入框、用户也收不掉它（实机：失败态键盘
        // 一直挂着）。键盘一要弹就收：只收终端的，不碰盖在本页之上的表单 / 弹窗输入框。
        .onReceive(NotificationCenter.default.publisher(
            for: UIResponder.keyboardWillShowNotification)) { _ in
            CoverKeyboardGuard.resignTerminalKeyboard()
        }
        .task {
            try? await Task.sleep(for: Self.revealDelay)
            guard !Task.isCancelled, !finishing else { return }
            revealed = true
        }
        // 连接耗时过长后露出「返回」；keyed by attempt → 重试时复位重新计时。
        .task(id: request.attempt) {
            canCancel = false
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            canCancel = true
        }
        // 已连接即闩锁（连上后即便立刻断开也按成功收尾，会话自身再展示断开态）。
        .onChange(of: connectedNow) { _, c in if c { commit() } }
        .onAppear { if connectedNow { commit() } }
        // 成功态停留片刻后进入会话。视图撤下时自动取消。
        .task(id: success) {
            guard success else { return }
            try? await Task.sleep(for: Self.successHold)
            guard !Task.isCancelled else { return }
            onFinish()
        }
        .animation(.easeOut(duration: 0.18), value: revealed)
        .animation(.easeOut(duration: 0.2), value: success)
        .animation(.easeOut(duration: 0.2), value: failureMessage != nil)
        .animation(.easeOut(duration: 0.2), value: canCancel)
    }

    /// 提交成功。内容还没露面就直接进会话（`revealed` 之后不会再置真，成功态的停留不会再触发）。
    private func commit() {
        guard !finishing else { return }
        finishing = true
        if !revealed { onFinish() }
    }

    // MARK: 顶部 chip

    private var topChip: some View {
        HStack(spacing: 7) {
            MIcon(name: isSftp ? "folder-tag" : "term", size: 14, color: accent)
            Text(isSftp ? "浏览文件" : (request.remote != nil ? "Mac 上的终端" : "终端会话"))
                .font(M.sans(12.5)).foregroundStyle(M.text2)
        }
        .padding(.horizontal, 13).padding(.vertical, 6)
        // 卡片形态：白卡靠与 canvas 的填充差区分，不加投影（与下方阶段卡一致）。
        .background(M.card)
        .clipShape(Capsule())
    }

    // MARK: 中部

    private var centerStack: some View {
        VStack(spacing: 0) {
            ConnRing(initial: initial, mode: ringMode)
            Text(host.name)
                .font(M.sans(22, weight: .bold)).tracking(-0.4).foregroundStyle(M.text)
                .lineLimit(1)
                .padding(.top, 22)
            endpointLine.padding(.top, 6)
            statusLine.padding(.top, 6)
        }
        .padding(.horizontal, 30)
    }

    private var initial: String { String(host.name.prefix(1)).uppercased() }

    @ViewBuilder private var endpointLine: some View {
        if let remote = request.remote {
            Text("经 \(remote.macName) 接入").foregroundStyle(M.text3)
                .font(M.sans(13))
                .lineLimit(1)
        } else {
            (Text("\(host.username)@\(host.host)").foregroundColor(M.text3)
                + Text(":\(String(host.port))").foregroundColor(M.text4))
                .font(M.mono(13))
                .lineLimit(1)
        }
    }

    @ViewBuilder private var statusLine: some View {
        Group {
            if success {
                Text(isSftp ? "已连接 · 正在打开文件…" : "已连接 · 正在打开会话…").foregroundStyle(M.success)
            } else if failureMessage != nil {
                Text("连接失败").foregroundStyle(M.danger)
            } else {
                Text(request.remote != nil ? "正在接入 Mac 上的终端…" : "正在建立安全连接…").foregroundStyle(M.text4)
            }
        }
        .font(M.sans(12.5))
    }

    // MARK: 底部

    @ViewBuilder private var bottomArea: some View {
        if let msg = failureMessage {
            VStack(spacing: 12) {
                Text(msg)
                    .font(M.sans(12.5)).foregroundStyle(M.danger)
                    .multilineTextAlignment(.center).lineSpacing(2)
                    .lineLimit(3).frame(maxWidth: 320)
                HStack(spacing: 10) {
                    MBtn(title: String(localized: "返回"), kind: .secondary, full: true, height: 48, action: onCancel)
                    MBtn(title: String(localized: "重试"), icon: "refresh", kind: .primary, full: true, height: 48, action: onRetry)
                }
                .frame(maxWidth: 320)
            }
            .transition(.opacity)
        } else if canCancel && !finishing {
            // 连接耗时过长仍未成功/失败：露出「返回」逃生口，避免卡在某一握手阶段无法退出。
            VStack(spacing: 10) {
                Text("连接耗时较长，可返回重试")
                    .font(M.sans(12.5)).foregroundStyle(M.text4)
                MBtn(title: String(localized: "返回"), kind: .secondary, full: true, height: 48, action: onCancel)
                    .frame(maxWidth: 320)
            }
            .transition(.opacity)
        }
        // 连接中（5s 内）/ 成功态：底部留空（不可中途中断）。固定高度仍保留，切换中部不位移。
    }
}

// MARK: - 进度环（设计稿 ConnRing）

/// 直径 ~100pt 的进度环：底环满圈分隔线色，上层强调色 25% 弧段匀速旋转（1.1s/圈，唯一动效）。
/// 环内 56pt 圆角方块显示主机名首字母；成功转绿显对勾、失败转红显叉。
private struct ConnRing: View {
    enum Mode { case connecting, success, failed }
    let initial: String
    let mode: Mode

    @Environment(\.mAccent) private var accent

    private var tint: Color {
        switch mode {
        case .connecting: return accent
        case .success: return M.success
        case .failed: return M.danger
        }
    }

    var body: some View {
        ZStack {
            Circle().stroke(M.border, lineWidth: 2.5).frame(width: 88, height: 88)
            switch mode {
            case .connecting:
                // 转圈走 CA（见 `uTerm/Shared/Views/CAMotion.swift`），不用 SwiftUI
                // `.repeatForever`：后者在整个连接期间把这一屏钉在满帧重绘上。
                // Reduce Motion 下弧静置不转，由 `SpinningArc` 内部处理。
                SpinningArc(color: accent, size: 88, lineWidth: 3, trim: 0.25, duration: 1.1)
            case .success, .failed:
                Circle()
                    .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: 88, height: 88)
            }
            innerTile
        }
        .frame(width: 100, height: 100)
    }

    private var innerTile: some View {
        RoundedRectangle(cornerRadius: MRadius.lg)
            .fill(tint.opacity(0.14))
            .frame(width: 56, height: 56)
            .overlay {
                switch mode {
                case .connecting:
                    Text(initial).font(M.mono(24, weight: .semibold)).foregroundStyle(accent)
                case .success:
                    MIcon(name: "check", size: 28, color: M.success, weight: .bold)
                case .failed:
                    MIcon(name: "x", size: 26, color: M.danger, weight: .bold)
                }
            }
    }
}

// MARK: - 中转页期间压住终端键盘

/// 找出当前第一响应者；若是终端视图就让它退位。
private enum CoverKeyboardGuard {
    private static weak var found: UIResponder?

    static func resignTerminalKeyboard() {
        found = nil
        UIApplication.shared.sendAction(#selector(UIResponder.mCaptureFirstResponder),
                                        to: nil, from: nil, for: nil)
        if let terminal = found as? MGhosttyTerminalView {
            _ = terminal.resignFirstResponder()
        }
        found = nil
    }

    fileprivate static func capture(_ responder: UIResponder) { found = responder }
}

private extension UIResponder {
    /// `sendAction(to: nil)` 沿响应链派给第一响应者，借它取到「当前是谁」。
    @objc func mCaptureFirstResponder() { CoverKeyboardGuard.capture(self) }
}

/// 格内连接中页按格裁切；整屏不裁（见 body 里的说明）。
private struct CoverPaneClip: ViewModifier {
    var enabled: Bool

    func body(content: Content) -> some View {
        if enabled { content.clipped() } else { content }
    }
}

/// 整屏时才按整块屏幕居中（`mCentersOnScreen`）；格内按格居中。
private struct CoverScreenCentering: ViewModifier {
    var enabled: Bool

    func body(content: Content) -> some View {
        if enabled { content.mCentersOnScreen() } else { content }
    }
}
