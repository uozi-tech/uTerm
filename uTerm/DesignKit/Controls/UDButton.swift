import SwiftUI

/// uTerm DesignKit 按钮族 —— 设计稿 `Components.html` Buttons 组。
///
/// `UDButton` 是 SwiftUI `Button` 的包装，四种风格（primary / secondary / ghost /
/// danger），统一 32 高、14 横向内边距、`UD.Radius.md` 圆角、`UD.control` 字体；
/// 通过自定义 `ButtonStyle` 读 hover（`.onHover`）+ `configuration.isPressed`。
///
/// 关键：深 / 浅两套配色由 `@Environment(\.colorScheme)` 驱动（见 `colors(...)`）。
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
            .modifier(UDConditionalShadow(enabled: c.shadow))
            .contentShape(RoundedRectangle(cornerRadius: UD.Radius.md, style: .continuous))
            .onHover { hovering = $0 }
    }

    // MARK: 配色映射（深 vs 浅 不同）

    private struct Palette {
        var bg: Color
        var border: Color
        var text: Color
        var shadow: Bool = false
    }

    private func colors(pressed: Bool) -> Palette {
        let dark = scheme == .dark
        let hover = hovering && isEnabled
        let down = pressed && isEnabled

        switch style {
        case .primary:
            if dark {
                guard isEnabled else {
                    return Palette(bg: UD.dyn(.white(0.03), .black(0.03)),
                                   border: .clear, text: UD.text4)
                }
                let bg = down ? UD.accent.opacity(0.26)
                              : hover ? UD.accent.opacity(0.19)
                                      : UD.accent.opacity(0.10)
                let border = hover ? UD.accent.opacity(0.47) : UD.accent.opacity(0.33)
                return Palette(bg: bg, border: border, text: UD.text)
            } else {
                guard isEnabled else {
                    return Palette(bg: UD.dyn(.white(0.03), .black(0.06)),
                                   border: .clear, text: UD.text4)
                }
                let bg = down ? UD.accentInk.opacity(0.85)
                              : hover ? UD.accentInk : UD.accent
                return Palette(bg: bg, border: .clear, text: .white, shadow: true)
            }

        case .secondary:
            if dark {
                guard isEnabled else {
                    return Palette(bg: UD.dyn(.white(0.045), .white(0.045)),
                                   border: UD.border, text: UD.text4)
                }
                let bg = hover ? UD.dyn(.white(0.08), .white(0.08))
                               : UD.dyn(.white(0.045), .white(0.045))
                return Palette(bg: bg, border: hover ? UD.borderHi : UD.border,
                               text: hover ? UD.text : UD.text2)
            } else {
                return Palette(bg: UD.panel, border: UD.borderHi,
                               text: isEnabled ? UD.text : UD.text4, shadow: true)
            }

        case .ghost:
            if dark {
                let bg = hover ? UD.dyn(.white(0.05), .black(0.05)) : .clear
                return Palette(bg: bg, border: .clear,
                               text: isEnabled ? (hover ? UD.text : UD.text2) : UD.text4)
            } else {
                let bg = hover ? UD.accentSoft : .clear
                return Palette(bg: bg, border: .clear,
                               text: isEnabled ? UD.accentInk : UD.text4)
            }

        case .danger:
            guard isEnabled else {
                return Palette(bg: UD.danger.opacity(0.08), border: UD.danger.opacity(0.27),
                               text: UD.text4)
            }
            let bg = hover ? UD.danger.opacity(0.14) : UD.danger.opacity(0.08)
            let border = hover ? UD.danger.opacity(0.40) : UD.danger.opacity(0.27)
            return Palette(bg: bg, border: border, text: UD.danger)
        }
    }
}

/// 条件投影 —— 仅 primary(light) / secondary(light) 需要 `.udShadow(.sm)`。
private struct UDConditionalShadow: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.udShadow(.sm) } else { content }
    }
}

// MARK: - UDIconButton

/// 28×28 纯图标钮（工具栏 / 行尾操作）。无描边；idle `UD.text3`，hover 底
/// `UD.panelHover` + 文本 `UD.text`，按下 y 偏移 0.5，禁用 `UD.text4`。
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
        let hover = hovering && isEnabled
        let text: Color = !isEnabled ? UD.text4 : (hover ? UD.text : UD.text3)
        return configuration.label
            .font(UD.control)
            .foregroundStyle(text)
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: UD.Radius.sm, style: .continuous)
                    .fill(hover ? UD.panelHover : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: UD.Radius.sm, style: .continuous))
            .onHover { hovering = $0 }
    }
}

// MARK: - Preview

#Preview {
    func gallery(_ scheme: ColorScheme) -> some View {
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
