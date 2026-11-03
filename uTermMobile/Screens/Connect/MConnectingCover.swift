import UDesignKit
import SwiftUI
import SwiftData
import Observation
import class SwiftTerm.TerminalView
import UIKit

/// 连接目标：终端会话 / SFTP 文件浏览（设计稿 `m-connect` 的 `kind`）。
enum MConnectKind: Hashable { case terminal, sftp }

/// 连接中页据以推进的统一阶段：连接中 / 已连接 / 失败（带错误文案）。
/// 由目标屏绑定的真实控制器状态映射而来（事件驱动，见 `MConnectRequest.phase`）。
enum MConnPhase: Equatable { case connecting, connected, failed(String) }

/// 一次「受保护连接」的请求：在选定主机与会话/文件浏览打开之间，根视图据此呈现全屏
/// 「连接中」中转页（设计稿 `m-shell` 的 `cover.type === 'connecting'`）。
///
/// 连接本体仍跑在目标屏（终端 / 文件）里——终端必须在建连期就把 `SwiftTermView` 挂上，
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
    /// 发起时工作区是否已展开（工作区里「+」新建）：取消后回到工作区，而不是收回主机列表。
    var originInWorkspace = false
    /// 强制新开会话（终端「+」新建：即便已有同主机会话也再开一个）。
    var allowDuplicate = false
    /// 连接尝试代次：重试时自增，驱动连接中页重跑阶段动画。
    var attempt = 0

    /// 连接中页是否只盖工作区里那个标签：分屏状态下、从工作区里发起（「+」/ 空格）的才是。
    func showsInPane(_ workspace: MobileWorkspace) -> Bool {
        originInWorkspace && workspace.isSplit
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
            // 连上后立刻断开（服务器关闭 / 网络抖动）：Observation 可能把 .connected 与 .closed
            // 合并到同一 tick，使连接中页观测不到 .connected。若曾连上过，把 .closed 也判为成功
            // 收尾（露出会话，由会话自身展示断开态），避免中转页卡死。
            case .closed: return t.hadConnected ? .connected : .connecting
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

/// 全屏「连接中」中转页。整页垂直三段：顶部胶囊 chip / 中部进度环 + 阶段卡片 / 底部长按取消。
/// 唯一动效是顶部进度环的匀速旋转；阶段行只用「点 / 对勾」三态静态表达。
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
    /// 格内且高度不够完整排版（进度环 + 阶段卡 + 底部区约 560pt）：只留进度环、名字与状态。
    private var compact: Bool { !fillsScreen && height > 0 && height < 560 }
    /// 阶段计时推进（仅在连接中、且最多到「认证」一项激活——绝不在 `.connected` 前把认证/会话标完成）。
    @State private var stageProgress = 0
    /// 已连接即闩锁（提交成功）：避免「连上即被服务器立刻断开」把状态翻回连接中导致卡死；
    /// 同时一旦提交即隐藏取消按钮，规避「已连上又被取消」竞态。
    @State private var finishing = false
    /// 连接态最短可见（~0.6s）后置真：瞬连时也先让连接动画走一段，避免状态一闪而过。
    @State private var minShown = false
    /// 连接耗时过长（~5s 仍未成功/失败）后露出「返回」逃生口：快速连接不显示，
    /// 保留「不可中途打断」的设计意图；卡在某一握手阶段（如认证）时给用户退路。
    @State private var canCancel = false

    private var isSftp: Bool { request.kind == .sftp }
    private var host: ServerProfile { request.host }
    private var phase: MConnPhase { request.phase }
    /// 原始已连接信号（用于闩锁触发）。
    private var connectedNow: Bool { phase == .connected }
    /// 显示用成功态：已提交且连接态已够时长。
    private var success: Bool { finishing && minShown }
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
    private var chipStatusRow: CGFloat? {
        guard fillsScreen, let row = chrome.statusRowHeight else { return nil }
        let limit = chrome.topBar?.maxX ?? chrome.statusBar?.minX ?? .infinity
        return chrome.screen.midX + Self.chipHalfWidth + 8 <= limit ? row : nil
    }

    /// chip 半宽的保守估计（「SFTP 文件」/「终端会话」两种文案，实测约 110pt 宽）。
    private static let chipHalfWidth: CGFloat = 64

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
            // Duo 展开竖屏：整条顶行都算安全区，chip 伸进去与状态栏同行（见 chipStatusRow）。
            .ignoresSafeArea(.container, edges: statusRow != nil ? .top : [])
            // 中转页对软键盘免疫：底层会话即便弹出键盘也不会顶起本页布局（防动画错乱）。
            .ignoresSafeArea(.keyboard, edges: .bottom)
            // Duo 状态栏在右侧一列时按整块屏幕居中，而不是按去掉那一列的宽度（看起来偏左）。
            .modifier(CoverScreenCentering(enabled: fillsScreen))
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .clipped()
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
        // 阶段计时推进；keyed by attempt → 重试时重跑并复位。
        .task(id: request.attempt) { stageProgress = 0; await pace() }
        // 连接态最短可见时长。
        .task { try? await Task.sleep(nanoseconds: 600_000_000); minShown = true }
        // 连接耗时过长后露出「返回」；keyed by attempt → 重试时复位重新计时。
        .task(id: request.attempt) {
            canCancel = false
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            canCancel = true
        }
        // 已连接即闩锁（连上后即便立刻断开也按成功收尾，会话自身再展示断开态）。
        .onChange(of: connectedNow) { _, c in if c { finishing = true } }
        .onAppear { if connectedNow { finishing = true } }
        // 成功态停留 ~0.7s 后进入会话。视图撤下时自动取消。
        .task(id: success) {
            guard success else { return }
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            onFinish()
        }
        .animation(.smooth(duration: 0.32), value: success)
        .animation(.smooth(duration: 0.3), value: failureMessage != nil)
        .animation(.smooth(duration: 0.3), value: finishing)
        .animation(.smooth(duration: 0.3), value: canCancel)
    }

    // 计时只推进到「认证」一项激活（解析 / 建立安全连接 两项标完成是允许的近似），
    // 认证完成与登录会话/子系统就绪一律等真实 `.connected`（事件驱动）。
    private func pace() async {
        let steps: [UInt64] = [520_000_000, 680_000_000]   // → 建立安全连接、→ 认证
        for ns in steps {
            try? await Task.sleep(nanoseconds: ns)
            if Task.isCancelled || finishing || failureMessage != nil { return }
            withAnimation(.easeOut(duration: 0.28)) { stageProgress = min(stageProgress + 1, 2) }
        }
    }

    // MARK: 顶部 chip

    private var topChip: some View {
        HStack(spacing: 7) {
            MIcon(name: isSftp ? "folder-tag" : "term", size: 14, color: accent)
            Text(isSftp ? "SFTP 文件" : "终端会话")
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
            if !compact { stageCard.padding(.top, 26) }
        }
        .padding(.horizontal, 30)
    }

    private var initial: String { String(host.name.prefix(1)).uppercased() }

    private var endpointLine: some View {
        (Text("\(host.username)@\(host.host)").foregroundColor(M.text3)
            + Text(":\(String(host.port))").foregroundColor(M.text4))
            .font(M.mono(13))
            .lineLimit(1)
    }

    @ViewBuilder private var statusLine: some View {
        Group {
            if success {
                Text("已连接 · 正在打开\(isSftp ? "文件" : "会话")…").foregroundStyle(M.success)
            } else if failureMessage != nil {
                Text("连接失败").foregroundStyle(M.danger)
            } else {
                Text("正在建立安全连接…").foregroundStyle(M.text4)
            }
        }
        .font(M.sans(12.5))
    }

    private var stageCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(stages.enumerated()), id: \.offset) { i, st in
                if i > 0 {
                    MRowDivider(inset: 0)
                }
                ConnStageRow(label: st.label, detail: st.detail, state: stageState(i))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .frame(maxWidth: 320)
        .background(M.card)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    /// 4 个握手阶段（终端 / SFTP 仅末项文案不同）。
    private var stages: [(label: String, detail: String)] {
        let authDetail = host.authMethod == .privateKey ? "publickey · ed25519" : "密码"
        let last: (String, String) = isSftp
            ? ("打开 SFTP 子系统", "sftp v3")
            : ("启动登录会话", "\(host.username) · pty")
        return [
            ("解析主机地址", host.host),
            ("建立安全连接", "curve25519 · chacha20"),
            ("认证身份", authDetail),
            last,
        ]
    }

    private func stageState(_ i: Int) -> ConnStageRow.StageState {
        if success { return .done }
        if failureMessage != nil {
            if i < stageProgress { return .done }
            return i == stageProgress ? .failed : .pending
        }
        if i < stageProgress { return .done }
        return i == stageProgress ? .active : .pending
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
                    MBtn(title: "返回", kind: .secondary, full: true, height: 48, action: onCancel)
                    MBtn(title: "重试", icon: "refresh", kind: .primary, full: true, height: 48, action: onRetry)
                }
                .frame(maxWidth: 320)
            }
            .transition(.opacity)
        } else if canCancel && !finishing {
            // 连接耗时过长仍未成功/失败：露出「返回」逃生口，避免卡在某一握手阶段无法退出。
            VStack(spacing: 10) {
                Text("连接耗时较长，可返回重试")
                    .font(M.sans(12.5)).foregroundStyle(M.text4)
                MBtn(title: "返回", kind: .secondary, full: true, height: 48, action: onCancel)
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
        RoundedRectangle(cornerRadius: 16)
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

// MARK: - 阶段行（设计稿 ConnStage）

/// 一行握手阶段：状态标记 + 标签 + 右侧 mono 细节。本身不带动效（动的只有进度环）。
private struct ConnStageRow: View {
    enum StageState { case pending, active, done, failed }
    let label: String
    let detail: String
    let state: StageState

    @Environment(\.mAccent) private var accent

    var body: some View {
        HStack(spacing: 12) {
            marker.frame(width: 18, height: 18)
            Text(label)
                .font(M.sans(14.5, weight: state == .active ? .semibold : .medium))
                .foregroundStyle(labelColor)
            Spacer(minLength: 6)
            if state == .done, !detail.isEmpty {
                Text(detail).font(M.mono(12)).foregroundStyle(M.text4).lineLimit(1)
            }
        }
        .padding(.vertical, 10).padding(.horizontal, 2)
    }

    @ViewBuilder private var marker: some View {
        switch state {
        case .done:
            MIcon(name: "check", size: 15, color: M.success, weight: .bold)
        case .failed:
            MIcon(name: "x", size: 14, color: M.danger, weight: .bold)
        case .active:
            Circle().fill(accent).frame(width: 8, height: 8)
        case .pending:
            Circle().fill(M.text4).frame(width: 6, height: 6).opacity(0.5)
        }
    }

    private var labelColor: Color {
        switch state {
        case .pending: return M.text4
        case .active: return M.text
        case .done: return M.text2
        case .failed: return M.danger
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
        if let terminal = found as? SwiftTerm.TerminalView {
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

/// 整屏时才按整块屏幕居中（`mCentersOnScreen`）；格内按格居中。
private struct CoverScreenCentering: ViewModifier {
    var enabled: Bool

    func body(content: Content) -> some View {
        if enabled { content.mCentersOnScreen() } else { content }
    }
}
