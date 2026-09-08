import UAppKitBridge
import UDesignKit
import SwiftUI

/// 单条转发隧道行（设计稿 `pages/port-forwarding.jsx` 的 `TunnelRow`）。
///
/// 主行 52pt：类型徽标 · 名称（150pt 固定列，含 autostart 闪电 + destLabel 副标题）·
/// 内联等宽流向（`源 → 目标`，dynamic 显「… · SOCKS5」，remote 箭头反向 `←`）·
/// hover 浮现编辑/删除 · 右侧 `UDToggle` 或红「异常」chip（共享 76pt 宽对齐）。
///
/// error 行：2pt 红色左栏 + 浅红底 + 浅红底分隔线 + 以**本规则名加粗开头**的原因条
/// （把行 + 原因条绑成一个单元，明确是哪条规则失败）；恢复操作「改端口」(conflict)
/// / 「重试」(其它) 同样 76pt 对齐。双击行 = 编辑。状态由外部 `status` 注入。
struct TunnelRow: View {
    let rule: ForwardingRule
    let status: TunnelStatus
    /// 规则仍 active 但近期有单连接开通道失败时的原因（nil = 正常）。琥珀警示 + tooltip。
    var recentIssue: String? = nil
    let isLast: Bool
    let onToggle: () -> Void
    let onRetry: () -> Void
    let onChangePort: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var hover = false

    /// 右侧状态列 / 恢复按钮共享宽度（对齐设计稿 PF_ACTION_W）。
    private static let actionWidth: CGFloat = 76
    /// hover 才浮现的「编辑 + 删除」两个 26pt 图标按钮 + 2pt 间距。
    /// 不悬停时用等宽占位块顶住，避免鼠标进出时整行几何跳动。
    private static let hoverActionsWidth: CGFloat = 26 + 2 + 26

    private var kind: ForwardKind { rule.kind }
    private var active: Bool { status == .active }
    private var isError: Bool { if case .error = status { return true } else { return false } }
    private var errorInfo: ForwardingError? {
        if case .error(let err) = status { return err } else { return nil }
    }
    private var isConflict: Bool { errorInfo?.kind == .conflict }

    var body: some View {
        VStack(spacing: 0) {
            mainRow
            if isError { errorStrip }
        }
        .background(isError ? UD.danger.opacity(0.05) : Color.clear)
        // error 行：2pt 红色左栏（替代设计稿 boxShadow inset 2px）。
        .overlay(alignment: .leading) {
            if isError {
                Rectangle().fill(UD.danger).frame(width: 2)
            }
        }
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle()
                    .fill(isError ? UD.danger.opacity(0.18) : UD.border)
                    .frame(height: 1)
            }
        }
    }

    // MARK: - 主行

    private var mainRow: some View {
        HStack(spacing: 12) {
            // 主内容区（徽标 · 名称 · 流向）：双击此区域 = 编辑。
            // 双击手势**只**挂在主内容区，刻意不覆盖尾部的编辑/删除按钮与开关——
            // 否则双击这些控件会同时触发本行的 count:2 手势（与按钮自身动作竞争）：
            // 弹层弹出后第二下又落到背板上 onCancel，导致 `editing` 在一拍内
            // value→nil→value 反复横跳、跨越刚插入的 overlay，把转场/AttributeGraph
            // 卡死（连点「编辑」直接卡页面的根因）。
            HStack(spacing: 12) {
                TypeBadge(kind: kind, dim: !active)

                // 名称列（150pt 固定）：名称(+autostart 闪电) + 可选 destLabel 副标题。
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(rule.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(active ? UD.text : UD.text2)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if rule.autostart {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(UD.text4)
                                // 行内 tooltip 一律走悬停门控：不悬停就不装那块常驻追踪区
                                // （一行 4 处 × 上百行，滚动时全要跟着重算）。
                                .help(whenHovering: hover, "连接时自动启动")
                        }
                    }
                    if let label = rule.destLabel, !label.isEmpty {
                        Text(label)
                            .font(.system(size: 11))
                            .foregroundStyle(UD.text4)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .frame(width: 150, alignment: .leading)

                // 内联等宽流向。
                flow
                    .font(UD.mono(12))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(active ? 1 : 0.5)
                    .help(whenHovering: hover, flowPlain)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: onEdit)

            // hover 编辑/删除。**悬停才建**：改前是常驻两个 `Button` 再 `opacity(0)` 藏起来，
            // 上百行时那就是上百对真控件。不悬停时换成等宽的占位色块，几何一模一样
            // （26 + 2 + 26 = 54pt），看得见的东西一点没变；无障碍也没变差 —— 完全透明的
            // 视图本来就被 SwiftUI 排除在无障碍树之外。
            HStack(spacing: 2) {
                if hover {
                    iconButton("pencil", tint: UD.text3, help: "编辑", action: onEdit)
                    iconButton("trash", tint: UD.danger, help: "删除", action: onDelete)
                } else {
                    Color.clear.frame(width: Self.hoverActionsWidth, height: 26)
                }
            }

            // 规则仍 active 但近期有单连接失败 → 琥珀警示（tooltip 给原因），消除「一直绿却连不上」误导。
            if active, let issue = recentIssue {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(UD.warning)
                    .help(whenHovering: hover, "最近连接失败：\(issue)")
                    .accessibilityLabel("最近连接失败：\(issue)")
            }
            // 右侧：error 显红 chip，否则 UDToggle。共享 76pt 宽。
            if isError {
                errorChip
            } else {
                UDToggle(Binding(get: { active }, set: { _ in onToggle() }))
                    .frame(width: Self.actionWidth, alignment: .trailing)
                    .accessibilityLabel(active ? "停止隧道「\(rule.name)」" : "启动隧道「\(rule.name)」")
            }
        }
        .padding(.leading, isError ? 14 : 12)
        .padding(.trailing, 12)
        .frame(height: 52)
        .background(!isError && hover ? UD.rowHover : Color.clear)
        .contentShape(Rectangle())
        // 滚动期间不接 hover（理由同 `GlobalForwardRow`）。
        .hoverGated { hover = $0 }
    }

    private var flow: Text {
        let src = Text("\(rule.listenHost):\(String(rule.listenPort))").foregroundStyle(UD.text)
        if kind == .dynamic {
            return Text("\(src)\(Text(" · SOCKS5").foregroundStyle(UD.text4))")
        }
        let arrow = Text(kind.reverse ? "  ←  " : "  →  ")
            .foregroundStyle(isError ? UD.danger : kind.tint)
        let dst = Text("\(rule.destHost ?? "")\(rule.destPort > 0 ? ":\(String(rule.destPort))" : "")")
            .foregroundStyle(UD.text2)
        return Text("\(src)\(arrow)\(dst)")
    }

    /// 流向纯文本（用于 .help / 无障碍，去掉富文本着色）。
    private var flowPlain: String {
        let src = "\(rule.listenHost):\(rule.listenPort)"
        if kind == .dynamic { return "\(src) · SOCKS5" }
        let arrow = kind.reverse ? " ← " : " → "
        let dst = "\(rule.destHost ?? "")\(rule.destPort > 0 ? ":\(rule.destPort)" : "")"
        return "\(src)\(arrow)\(dst)"
    }

    private var errorChip: some View {
        HStack(spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9))
            Text("异常")
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(UD.danger)
        .frame(width: Self.actionWidth, height: 24)
        .background(RoundedRectangle(cornerRadius: 6).fill(UD.danger.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(UD.danger.opacity(0.3), lineWidth: 1))
    }

    // MARK: - 原因条

    /// 原因条文案：本规则名（加粗）— 错误信息。用 Text 插值拼接（macOS 26 弃用 Text + Text）。
    private var reasonText: Text {
        let name = Text(rule.name).font(.system(size: 12, weight: .medium)).foregroundStyle(UD.text)
        let dash = Text(" — ").foregroundStyle(UD.text4)
        let msg = Text(errorInfo?.message ?? "").foregroundStyle(UD.text2)
        return Text("\(name)\(dash)\(msg)")
    }

    private var errorStrip: some View {
        HStack(spacing: 9) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 11))
                .foregroundStyle(UD.danger)
            // 以本规则名加粗开头，避免与原因里可能提到的冲突服务名混淆。
            reasonText
                .font(.system(size: 12))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            if isConflict {
                recoveryButton("改端口", icon: nil, action: onChangePort)
            } else {
                recoveryButton("重试", icon: "arrow.clockwise", action: onRetry)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .padding(.bottom, 11)
    }

    // MARK: - 小部件

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

    private func recoveryButton(_ title: String, icon: String?,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 10))
                }
                Text(title)
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(UD.text2)
            .frame(width: Self.actionWidth, height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(UD.fillSoft))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 类型徽标

/// 类型徽标（设计稿 `TypeBadge`）：类型短名 + flag（mono），类型色低透明底；
/// `dim`（隧道未活跃）时退成中性灰底。
struct TypeBadge: View {
    let kind: ForwardKind
    let dim: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(kind.shortLabel)
                .font(.system(size: 11, weight: .semibold))
            Text(kind.flag)
                .font(UD.mono(10))
                .opacity(0.7)
        }
        .foregroundStyle(dim ? UD.text3 : kind.tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 5)
            .fill(dim ? UD.fillSoft : kind.tint.opacity(0.14)))
        .fixedSize()
    }
}
