import SwiftUI

/// uTerm DesignKit 实体浮层菜单 —— 下拉 / 上下文菜单 / 列表（设计稿 `Components.html` Menu）。
///
/// 纯展示组件：只读 `UD` token + 普通值输入，不依赖任何 domain model。
/// **实底，无模糊**（背景 `UD.overlay`），与 popover/玻璃面区分。选中态用
/// `UD.rowSelected` 实底 + 尾部对勾，hover 用白/黑 5% 叠加，其余透明。
struct UDMenu: View {
    /// 菜单宽度。
    let width: CGFloat
    /// 可选分组标题（全大写小标签）。
    let head: String?
    /// 菜单项（含分隔线）。
    let items: [UDMenuItem]

    init(width: CGFloat = 200, head: String? = nil, items: [UDMenuItem]) {
        self.width = width
        self.head = head
        self.items = items
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let head {
                Text(head.uppercased())
                    .font(UD.font(10.5))
                    .foregroundStyle(UD.text4)
                    .padding(.top, 4)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            ForEach(items) { item in
                if item.isDivider {
                    Rectangle()
                        .fill(UD.border)
                        .frame(height: 1)
                        .padding(.horizontal, 2)
                        .padding(.vertical, 4)
                } else {
                    UDMenuItemRow(item: item)
                }
            }
        }
        .padding(4)
        .frame(width: width)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(UD.overlay)
        )
        .overlay(
            // 浮层细发丝边：单层 UD.border（白 7% / 黑 10%），无内高光。
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(UD.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .udShadow(.md)
    }
}

/// 单条菜单行（hover 态内部自管理）。
private struct UDMenuItemRow: View {
    let item: UDMenuItem
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            if let dotColor = item.dotColor {
                Circle()
                    .fill(dotColor)
                    .frame(width: 6, height: 6)
            } else if let systemImage = item.systemImage {
                Image(systemName: systemImage)
                    .font(UD.font(12.5))
                    .foregroundStyle(foreground)
                    .frame(width: 14)
            }

            Text(item.label)
                .font(UD.font(12.5))
                .foregroundStyle(foreground)
                .frame(maxWidth: .infinity, alignment: .leading)

            if item.active {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(UD.accent)
            } else if let kbd = item.kbd {
                Text(kbd)
                    .font(UD.mono(10))
                    .foregroundStyle(UD.text4)
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 9)
        .background(
            RoundedRectangle(cornerRadius: UD.Radius.sm)
                .fill(background)
        )
        .contentShape(RoundedRectangle(cornerRadius: UD.Radius.sm))
        .onHover { hovered = $0 }
    }

    private var foreground: Color {
        if item.danger { return UD.danger }
        return item.active ? UD.text : UD.text2
    }

    private var background: Color {
        if item.active { return UD.rowSelected }
        if hovered { return UD.dyn(.white(0.05), .black(0.05)) }
        return .clear
    }
}

/// uTerm DesignKit 菜单项模型 —— `UDMenu` 的数据载体。
///
/// `isDivider == true` 时只渲染一条分隔线，其余字段忽略；用 `.divider()` 构造。
struct UDMenuItem: Identifiable {
    let id = UUID()
    /// 行标题。
    var label: String
    /// 前导 SF Symbol 名（与 `dotColor` 二选一，`dotColor` 优先）。
    var systemImage: String?
    /// 前导 6pt 圆点色（模型 / 状态指示）。
    var dotColor: Color?
    /// 尾部快捷键标签（`active` 时被对勾取代）。
    var kbd: String?
    /// 选中态：实底 + 尾部对勾。
    var active: Bool
    /// 危险项：文本染 `UD.danger`。
    var danger: Bool
    /// 是否为分隔线。
    var isDivider: Bool

    init(
        label: String,
        systemImage: String? = nil,
        dotColor: Color? = nil,
        kbd: String? = nil,
        active: Bool = false,
        danger: Bool = false,
        isDivider: Bool = false
    ) {
        self.label = label
        self.systemImage = systemImage
        self.dotColor = dotColor
        self.kbd = kbd
        self.active = active
        self.danger = danger
        self.isDivider = isDivider
    }

    /// 分隔线项。
    static func divider() -> UDMenuItem {
        UDMenuItem(label: "", isDivider: true)
    }
}

#Preview {
    HStack(alignment: .top, spacing: 24) {
        // (a) 模型选择器
        UDMenu(width: 184, head: "模型", items: [
            UDMenuItem(label: "claude-sonnet", dotColor: UD.accent, active: true),
            UDMenuItem(label: "claude-opus", dotColor: UD.accentViolet),
            UDMenuItem(label: "claude-haiku", dotColor: UD.success),
        ])

        // (b) 上下文菜单
        UDMenu(items: [
            UDMenuItem(label: "在终端打开", systemImage: "terminal", kbd: "↩"),
            UDMenuItem(label: "复制路径", systemImage: "doc.on.doc", kbd: "⌘C"),
            UDMenuItem(label: "重命名", systemImage: "pencil"),
            .divider(),
            UDMenuItem(label: "删除", systemImage: "trash", kbd: "⌫", danger: true),
        ])
    }
    .padding(40)
    .background(UD.bg)
}
