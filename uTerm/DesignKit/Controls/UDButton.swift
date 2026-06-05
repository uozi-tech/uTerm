import SwiftUI

/// uTerm DesignKit 按钮族 —— 设计稿 `Components.html` Buttons 组。
///
/// `UDButton` 是 SwiftUI `Button` 的包装，四种风格（primary / secondary / ghost /
/// danger），统一 32 高、14 横向内边距、`UD.Radius.md` 圆角、`UD.control` 字体；
/// 通过自定义 `ButtonStyle` 读 hover（`.onHover`）+ `configuration.isPressed`。
///
/// 设计稿约定：**状态切换仅靠底色与描边——无位移（transform）、无四周投影（shadow）**。
/// 按下（active）用去饱和板岩蓝 `UD.accentPressed` 收敛，而非更亮的 hover 色。
/// 深 / 浅两套配色由 `@Environment(\.colorScheme)` 驱动（见 `colors(...)`）。
/// 纯展示组件，只读 `UD` token + 普通值输入，不依赖任何 domain model。
struct UDButton: View {
    /// 按钮风格。
    enum Style {
        case primary, secondary, ghost, danger
    }

    let title: String
    var style: Style = .primary
    var systemImage: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
        }
        .buttonStyle(UDButtonStyle(style: style))
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
            if dark {
                guard isEnabled else {
                    return Palette(bg: .white.opacity(0.03), border: UD.border, text: UD.text4)
                }
                if down {   // active：去饱和板岩蓝叠加 + 白字（按下往回收，非更亮）
                    return Palette(bg: UD.accentPressed.opacity(0.26),
                                   border: UD.accentPressed.opacity(0.55), text: .white)
                }
                let bg = hover ? UD.accent.opacity(0.19) : UD.accent.opacity(0.10)
                let border = hover ? UD.accent.opacity(0.47) : UD.accent.opacity(0.33)
                return Palette(bg: bg, border: border, text: UD.text)
            } else {
                guard isEnabled else {
                    return Palette(bg: .black.opacity(0.06), border: .clear, text: UD.text4)
                }
                // 实心填充：default accent → hover accentInk → active 板岩蓝。
                let bg = down ? UD.accentPressed : (hover ? UD.accentInk : UD.accent)
                return Palette(bg: bg, border: .clear, text: .white)
            }

        case .secondary:
            if dark {
                guard isEnabled else {
                    return Palette(bg: .clear, border: UD.border, text: UD.text4)
                }
                if down {
                    return Palette(bg: .white.opacity(0.11), border: UD.borderHi, text: UD.text)
                }
                let bg: Color = hover ? .white.opacity(0.08) : .white.opacity(0.045)
                return Palette(bg: bg, border: hover ? UD.borderHi : UD.border,
                               text: hover ? UD.text : UD.text2)
            } else {
                guard isEnabled else {
                    return Palette(bg: UD.panel, border: UD.border, text: UD.text4)
                }
                let bg = down ? Self.secondaryPressedLight : (hover ? UD.panelHi : UD.panel)
                return Palette(bg: bg, border: UD.borderHi, text: UD.text)
            }

        case .ghost:
            guard isEnabled else {
                return Palette(bg: .clear, border: .clear, text: UD.text4)
            }
            if dark {
                let bg: Color = down ? .white.opacity(0.08)
                                     : (hover ? .white.opacity(0.05) : .clear)
                return Palette(bg: bg, border: .clear, text: (hover || down) ? UD.text : UD.text2)
            } else {
                let bg: Color = down ? UD.accent.opacity(0.16)
                                     : (hover ? UD.accentSoft : .clear)
                return Palette(bg: bg, border: .clear, text: UD.accentInk)
            }

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

    /// 浅色次按钮按下态实底（设计稿 #EEEDE9，暖中性灰）。
    private static let secondaryPressedLight = UD.ColorSpec.hex(0xEEEDE9).color()
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
