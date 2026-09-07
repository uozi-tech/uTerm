import UDesignKit
import SwiftUI
import SwiftData

/// 全局端口转发面板里的一行。
///
/// 设计：**每条规则只有一个「保持连接」开关**（合并了旧版的「自启」胶囊 + 开/关开关）。
/// - 开 = 立即建立隧道 + 持久化（`launchAtAppStart`，随 uTerm 启动自动建立）+ 断线自愈。
/// - 关 = 断开并清除标记。
/// 点一下当场就连，所见即所得 —— 不再有「点了没反应、要等下次启动」的延迟困惑。
/// 行内 `TunnelStatusBadge` 实时显示连接中 / 已连接 / 失败（可重试）/ 未连接。
///
/// 注：`launchAtAppStart` 在 UI 上叫「保持连接」；它与单主机页的连接级 `autostart`
/// （连到该主机时自动起）仍是两个独立标志（见 spec §5）。
struct GlobalForwardRow: View {
    let rule: ForwardingRule
    let server: ServerProfile
    let relay: HostKeyChallengeRelay
    let isLast: Bool
    /// 本规则的实时流量（累计 + 速率）；面板每秒刷新。-R 无数据。
    let traffic: GFTrafficStat?
    /// 编辑本规则配置（双击主内容区 / hover 铅笔触发）。
    let onEdit: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(ForwardingCoordinator.self) private var coordinator
    @State private var hover = false

    private static let nameWidth: CGFloat = 138

    private var status: TunnelStatus { coordinator.status(rule.id) }
    private var active: Bool { status == .active }
    private var isError: Bool { if case .error = status { return true }; return false }
    private var errorMessage: String? {
        if case .error(let e) = status { return e.message }
        return nil
    }
    /// 规则仍 active 但近期有单连接开通道失败 → 徽标转琥珀「已连接·近期失败」，
    /// 消除 wedge 期「一直绿的已连接却连不上」的误导。
    private var recentIssue: String? {
        active ? coordinator.connectionIssue(rule.id)?.reason : nil
    }

    var body: some View {
        HStack(spacing: 12) {
            // 主内容区（徽标 · 名称 · 流向）：双击 = 编辑配置。双击手势**只**挂主内容区，刻意不
            // 覆盖尾部铅笔/状态/开关——否则与控件自身动作竞争、弹层一拍内反复横跳卡页面
            // （见 TunnelRow 双击注释）。
            HStack(spacing: 12) {
                TypeBadge(kind: rule.kind, dim: !active)

                VStack(alignment: .leading, spacing: 2) {
                    Text(rule.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(active ? UD.text : UD.text2)
                        .lineLimit(1).truncationMode(.tail)
                    if let label = rule.destLabel, !label.isEmpty {
                        Text(label)
                            .font(.system(size: 11)).foregroundStyle(UD.text4)
                            .lineLimit(1).truncationMode(.tail)
                    }
                }
                .frame(width: Self.nameWidth, alignment: .leading)

                flow
                    .font(UD.mono(12)).lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(active ? 1 : 0.5)
                    // 行内 tooltip 一律走悬停门控：不悬停就不装那块常驻追踪区
                    // （一行 5 处 × 上千行，滚动时全要跟着重算）。见 `help(whenHovering:)`。
                    .help(whenHovering: hover, flowPlain)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: onEdit)

            // hover 浮现「编辑配置」铅笔（双击的可发现入口）。
            iconButton("pencil", tint: UD.text3, help: "编辑配置", action: onEdit)
                .opacity(hover ? 1 : 0)

            trafficView

            TunnelStatusBadge(status: status, recentIssue: recentIssue, onRetry: retry)
                .help(whenHovering: hover,
                      errorMessage ?? recentIssue.map { "最近连接失败：\($0)" } ?? "")

            UDToggle(Binding(get: { rule.launchAtAppStart }, set: { setKeepConnected($0) }))
                .help(whenHovering: hover, "保持连接 · 随 uTerm 启动自动建立")
                .accessibilityLabel(rule.launchAtAppStart
                    ? "停止并取消保持「\(rule.name)」" : "保持连接「\(rule.name)」")
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
        .background(hover ? UD.rowHover : Color.clear)
        .overlay(alignment: .bottom) {
            if !isLast { Rectangle().fill(UD.border).frame(height: 1) }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }

    /// hover 浮现的小图标按钮（镜像 `TunnelRow.iconButton`）。
    /// hover 才浮现的小图标按钮：tooltip 同样只在悬停时才装（按钮本身 `opacity(0)`
    /// 时根本看不到，常驻一块 tooltip 区纯属浪费）。AX 标签不门控，读屏任何时候都要读得到。
    private func iconButton(_ symbol: String, tint: Color, help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(whenHovering: hover, help)
        .accessibilityLabel(help)
    }

    // MARK: - 流向

    /// 内联等宽流向：`src → dst`（remote 用 `←`，dynamic 显示 `· SOCKS5`）。镜像 `TunnelRow.flow`。
    private var flow: Text {
        let src = Text("\(rule.listenHost):\(String(rule.listenPort))").foregroundStyle(UD.text)
        if rule.kind == .dynamic {
            return Text("\(src)\(Text(" · SOCKS5").foregroundStyle(UD.text4))")
        }
        let arrow = Text(rule.kind.reverse ? "  ←  " : "  →  ")
            .foregroundStyle(isError ? UD.danger : rule.kind.tint)
        let dst = Text("\(rule.destHost ?? "")\(rule.destPort > 0 ? ":\(String(rule.destPort))" : "")")
            .foregroundStyle(UD.text2)
        return Text("\(src)\(arrow)\(dst)")
    }

    private var flowPlain: String {
        if rule.kind == .dynamic { return "\(rule.listenHost):\(rule.listenPort) · SOCKS5" }
        let arrow = rule.kind.reverse ? " ← " : " → "
        let dst = "\(rule.destHost ?? "")\(rule.destPort > 0 ? ":\(rule.destPort)" : "")"
        return "\(rule.listenHost):\(rule.listenPort)\(arrow)\(dst)"
    }

    // MARK: - 流量

    /// 实时速率 ↑/↓（每秒刷新），仅在已连接且可统计（非 `-R`）时显示；累计总量放 tooltip。
    /// `-R` 走 Citadel 内部转发、不经粘合点 → 不显示（hover 状态徽标可知已连接）。
    private var trafficView: some View {
        // 固定列宽常驻：未连接 / 连接中 / -R 时留空但保宽，避免隧道一连上 flow 文本被挤、列错位跳动。
        Group {
            if rule.kind != .remote, active, let t = traffic {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("↑ \(gfFormatRate(t.upRate))")
                    Text("↓ \(gfFormatRate(t.downRate))")
                }
                .font(UD.mono(10))
                .foregroundStyle(UD.text3)
                .lineLimit(1)
                .help(whenHovering: hover,
                      "累计  ↑ \(gfFormatBytes(t.up)) · ↓ \(gfFormatBytes(t.down))")
            }
        }
        .frame(width: 104, alignment: .trailing)
    }

    // MARK: - 动作

    /// 「保持连接」开关：开 = 持久化 + 立即建立；关 = 清除 + 断开。所见即所得。
    private func setKeepConnected(_ on: Bool) {
        rule.launchAtAppStart = on
        try? modelContext.save()
        if on {
            // 已经活跃就不重起（避免抖断 —— 比如从单主机页起好的隧道）。
            guard status != .active else { return }
            coordinator.start(rule.snapshot, on: server,
                              relay: relay, modelContainer: modelContext.container)
        } else {
            coordinator.stop(rule.id)
        }
    }

    private func retry() {
        coordinator.retry(rule.snapshot, on: server,
                          relay: relay, modelContainer: modelContext.container)
    }
}

// MARK: - 状态徽标

/// 一条隧道的实时状态（只读 + 失败可重试）：未连接 / 连接中 / 已连接 / 失败。
/// 由 `ForwardingCoordinator.status(_:)` 驱动 —— 启动序列与手动开关共用同一套状态。
struct TunnelStatusBadge: View {
    let status: TunnelStatus
    /// 规则仍 active 但近期有单连接开通道失败时的原因（nil = 正常）。非空 → 徽标转琥珀，
    /// 加警示三角 + tooltip，提示「已连接但近期有连接失败」，消除 wedge 期的误导。
    var recentIssue: String? = nil
    let onRetry: () -> Void

    var body: some View {
        Group {
            switch status {
            case .inactive:
                dotLabel("未连接", dot: UD.text4, text: UD.text4)
            case .starting:
                HStack(spacing: 5) {
                    ProgressView().controlSize(.small).tint(UD.accent)
                    Text("连接中").font(.system(size: 11)).foregroundStyle(UD.accent)
                }
            case .active:
                if recentIssue != nil {
                    HStack(spacing: 5) {
                        Circle().fill(UD.warning).frame(width: 6, height: 6)
                        Text("已连接").font(.system(size: 11)).foregroundStyle(UD.warning)
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 8)).foregroundStyle(UD.warning)
                    }
                } else {
                    dotLabel("已连接", dot: UD.success, text: UD.success)
                }
            case .error:
                Button(action: onRetry) {
                    HStack(spacing: 5) {
                        Circle().fill(UD.danger).frame(width: 6, height: 6)
                        Text("失败").font(.system(size: 11, weight: .medium))
                        Image(systemName: "arrow.clockwise").font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(UD.danger)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 74, alignment: .trailing)
    }

    private func dotLabel(_ text: String, dot: Color, text textColor: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(dot).frame(width: 6, height: 6)
            Text(text).font(.system(size: 11)).foregroundStyle(textColor)
        }
    }
}
