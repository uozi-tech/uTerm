import SwiftUI

/// uTerm DesignKit 按钮族 —— 设计稿 `Components.html` Buttons 组。
///
/// `UDButton` 是 SwiftUI `Button` 的包装，四种风格（primary / secondary / ghost /
/// danger），统一 32 高、14 横向内边距、`UD.Radius.md` 圆角、`UD.control` 字体；
/// 通过自定义 `ButtonStyle` 读 hover（`.onHover`）+ `configuration.isPressed`。
///
/// v2「填充即边界」：**有填充就没有描边**——tint / 灰填充按钮一律无 1px 描边（保留
/// 1px 透明占位防跳动），状态切换仅靠底色；唯 danger 保留红色状态描边。
/// 按下（active）用去饱和板岩蓝 `UD.accentPressed` 收敛，而非更亮的 hover 色。
/// 纯展示组件，只读 `UD` token + 普通值输入，不依赖任何 domain model。
struct UDButton: View {
    /// 按钮风格。
    enum Style {
        case primary, secondary, ghost, danger
    }

    let title: String
    var style: Style = .primary
    var systemImage: String? = nil
    /// 按钮内尾部的键位提示（如 "esc"、"⌘↵"）；nil 不显示。随按钮文本色自适应。
    var trailingHint: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
                if let trailingHint {
                    UDButtonKbd(text: trailingHint).padding(.leading, 1)
                }
            }
        }
        .buttonStyle(UDButtonStyle(style: style))
    }
}

/// 按钮内嵌的键位小帽：背景用当前前景色的低透明度叠底，文本继承按钮前景色，
/// 故在实心 / 半透明 / 各风格按钮上都自洽（无需感知具体风格）。
private struct UDButtonKbd: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(0.14))
            )
            .opacity(0.9)
    }
}

// MARK: - ButtonStyle

private struct UDButtonStyle: ButtonStyle {
    let style: UDButton.Style
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var scheme

    func makeBody(configuration: Configuration) -> some View {
        let c = colors(pressed: configuration.isPressed)
        configuration.label
            .font(UD.control)
            .foregroundStyle(c.text)
            .frame(height: 32)
            .padding(.horizontal, 14)
            .background(
                RoundedRectangle(cornerRadius: UD.Radius.md, style: .continuous)
                    .fill(c.bg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: UD.Radius.md, style: .continuous)
                    .strokeBorder(c.border, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: UD.Radius.md, style: .continuous))
            .onHover { hovering = $0 }
    }

    // MARK: 配色映射（深 vs 浅 不同）

    private struct Palette {
        var bg: Color
        var border: Color
        var text: Color
    }

    /// 解析当前视觉态配色。优先级：禁用 → 按下(active) → 悬停 → 默认；
    /// 全程仅切底色 / 描边 / 文本——不加位移与投影（对齐设计稿 `kit-controls` 按钮规范）。
    private func colors(pressed: Bool) -> Palette {
        let dark = scheme == .dark
        let hover = hovering && isEnabled
        let down = pressed && isEnabled

        switch style {
        case .primary:
            // 「驾驶舱」高亮形式（双主题同构）：accent 14% tint 底 + accent 文字/图标、
            // 无描边；hover 22%（设计稿 accent24 / accent38）。
            guard isEnabled else {
                return Palette(bg: dark ? Color.white.opacity(0.03) : Color.black.opacity(0.06),
                               border: .clear, text: UD.text4)
            }
            if down {   // active：去饱和板岩蓝收敛（按下往回收，非更亮）
                return Palette(bg: UD.accentPressed.opacity(0.26), border: .clear,
                               text: dark ? .white : UD.accentInk)
            }
            let bg = hover ? UD.accent.opacity(0.22) : UD.accentSoft
            return Palette(bg: bg, border: .clear, text: UD.accentInk)

        case .secondary:
            // 中性淡灰填充、无描边（--uw 阶梯，深浅同规则；不再有「白底 + 描边」形态）。
            guard isEnabled else {
                return Palette(bg: UD.dyn(.white(0.055), .black(0.065)), border: .clear,
                               text: UD.text4)
            }
            if down {
                return Palette(bg: UD.dyn(.white(0.11), .black(0.11)), border: .clear, text: UD.text)
            }
            let bg = hover ? UD.dyn(.white(0.08), .black(0.085))
                           : UD.dyn(.white(0.045), .black(0.055))
            return Palette(bg: bg, border: .clear, text: hover ? UD.text : UD.text2)

        case .ghost:
            // 幽灵：静止透明，hover / active 淡灰填充（中性，深浅同规则），无描边。
            guard isEnabled else {
                return Palette(bg: .clear, border: .clear, text: UD.text4)
            }
            let bg: Color = down ? UD.dyn(.white(0.08), .black(0.085))
                                 : (hover ? UD.dyn(.white(0.05), .black(0.06)) : .clear)
            return Palette(bg: bg, border: .clear, text: (hover || down) ? UD.text : UD.text2)

        case .danger:
            guard isEnabled else {
                return Palette(bg: UD.danger.opacity(0.08), border: UD.danger.opacity(0.27),
                               text: UD.text4)
            }
            let active = hover || down
            let bg = active ? UD.danger.opacity(0.14) : UD.danger.opacity(0.08)
            let border = active ? UD.danger.opacity(0.40) : UD.danger.opacity(0.27)
            return Palette(bg: bg, border: border, text: UD.danger)
        }
    }
}

// MARK: - UDIconButton

/// 28×28 纯图标钮（工具栏 / 行尾操作）。无描边；idle `UD.text3`，hover 底
/// `UD.panelHover` + 文本 `UD.text`，按下(active)叠更亮底（深 white 12% / 浅 black 10%），
/// 禁用 `UD.text4`。仅切底色与文本，无位移、无投影。
struct UDIconButton: View {
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
        }
        .buttonStyle(UDIconButtonStyle())
    }
}

private struct UDIconButtonStyle: ButtonStyle {
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let down = configuration.isPressed && isEnabled
        let hover = hovering && isEnabled
        let text: Color = !isEnabled ? UD.text4 : ((hover || down) ? UD.text : UD.text3)
        let bg: Color = down ? UD.dyn(.white(0.12), .black(0.10))
                             : (hover ? UD.panelHover : .clear)
        return configuration.label
            .font(UD.control)
            .foregroundStyle(text)
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: UD.Radius.sm, style: .continuous)
                    .fill(bg)
            )
            .contentShape(RoundedRectangle(cornerRadius: UD.Radius.sm, style: .continuous))
            .onHover { hovering = $0 }
    }
}

// MARK: - Preview

#Preview {
    @MainActor func gallery(_ scheme: ColorScheme) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach([("primary", UDButton.Style.primary),
                     ("secondary", .secondary),
                     ("ghost", .ghost),
                     ("danger", .danger)], id: \.0) { name, style in
                HStack(spacing: 12) {
                    Text(name)
                        .font(UD.caption)
                        .foregroundStyle(UD.text3)
                        .frame(width: 72, alignment: .leading)
                    UDButton(title: "默认", style: style) {}
                    UDButton(title: "禁用", style: style) {}
                        .disabled(true)
                }
            }

            HStack(spacing: 12) {
                Text("icon")
                    .font(UD.caption)
                    .foregroundStyle(UD.text3)
                    .frame(width: 72, alignment: .leading)
                UDButton(title: "新建服务器", style: .primary, systemImage: "plus") {}
            }

            HStack(spacing: 8) {
                Text("icon钮")
                    .font(UD.caption)
                    .foregroundStyle(UD.text3)
                    .frame(width: 72, alignment: .leading)
                UDIconButton(systemImage: "pencil") {}
                UDIconButton(systemImage: "trash") {}
                UDIconButton(systemImage: "arrow.clockwise") {}
                UDIconButton(systemImage: "ellipsis") {}
                    .disabled(true)
            }
        }
        .padding(24)
        .frame(width: 360, alignment: .leading)
        .background(UD.bg)
        .environment(\.colorScheme, scheme)
    }

    return HStack(spacing: 0) {
        gallery(.dark)
        gallery(.light)
    }
}
