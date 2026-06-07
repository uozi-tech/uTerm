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
    let isLast: Bool
    let onToggle: () -> Void
    let onRetry: () -> Void
    let onChangePort: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var hover = false

    /// 右侧状态列 / 恢复按钮共享宽度（对齐设计稿 PF_ACTION_W）。
    private static let actionWidth: CGFloat = 76

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
                            .help("连接时自动启动")
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

            // hover 编辑/删除。
            HStack(spacing: 2) {
                iconButton("pencil", tint: UD.text3, help: "编辑", action: onEdit)
                iconButton("trash", tint: UD.danger, help: "删除", action: onDelete)
            }
            .opacity(hover ? 1 : 0)

            // 右侧：error 显红 chip，否则 UDToggle。共享 76pt 宽。
            if isError {
                errorChip
            } else {
                UDToggle(Binding(get: { active }, set: { _ in onToggle() }))
                    .frame(width: Self.actionWidth, alignment: .trailing)
            }
        }
        .padding(.leading, isError ? 14 : 12)
        .padding(.trailing, 12)
        .frame(height: 52)
        .background(!isError && hover ? UD.rowHover : Color.clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2, perform: onEdit)
    }

    @ViewBuilder
    private var flow: some View {
        if kind == .dynamic {
            (Text("\(rule.listenHost):\(rule.listenPort)").foregroundStyle(UD.text)
             + Text(" · SOCKS5").foregroundStyle(UD.text4))
        } else {
            (Text("\(rule.listenHost):\(rule.listenPort)").foregroundStyle(UD.text)
             + Text(kind.reverse ? "  ←  " : "  →  ")
                 .foregroundStyle(isError ? UD.danger : kind.tint)
             + Text("\(rule.destHost ?? "")\(rule.destPort > 0 ? ":\(rule.destPort)" : "")")
                 .foregroundStyle(UD.text2))
        }
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
        .background(RoundedRectangle(cornerRadius: 6).fill(UD.danger.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(UD.danger.opacity(0.3), lineWidth: 1))
    }

    // MARK: - 原因条

    private var errorStrip: some View {
        HStack(spacing: 9) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 11))
                .foregroundStyle(UD.danger)
            // 以本规则名加粗开头，避免与原因里可能提到的冲突服务名混淆。
            (Text(rule.name).font(.system(size: 12, weight: .medium)).foregroundStyle(UD.text)
             + Text(" — ").foregroundStyle(UD.text4)
             + Text(errorInfo?.message ?? "").foregroundStyle(UD.text2))
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
        .help(help)
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
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(UD.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 类型徽标

/// 类型徽标（设计稿 `TypeBadge`）：类型短名 + flag（mono），类型色低透明底 + 同色描边；
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
            .fill(dim ? UD.fillSoft : kind.tint.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 5)
            .strokeBorder(dim ? UD.border : kind.tint.opacity(0.25), lineWidth: 1))
        .fixedSize()
    }
}
