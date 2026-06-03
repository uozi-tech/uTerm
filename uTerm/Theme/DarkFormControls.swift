import SwiftUI

/// 设计稿 `new-server.jsx` / `keys.jsx` 里的表单原语翻译成 SwiftUI。全部用
/// `WS` 暗色 token，专供「新建服务器」表单与「密钥管理」窗口复用 —— 两处都
/// 被钉为 `.darkAqua`，故这里的实色恒成立，不随全局浅 / 深外观变化。
///
/// 设计稿对应：`Input` / `Segmented` / `Switch` / `FormSection` / `FormField`
/// / `Button` / 分组 chip。

// MARK: - 文本输入

/// 设计稿 `Input`：h32、圆角 7、focus 时描边换 accent，可选等宽字体。
struct DarkTextField: View {
    let placeholder: String
    @Binding var text: String
    var mono: Bool = false

    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(WS.text4))
            .textFieldStyle(.plain)
            .focused($focused)
            .font(mono ? WS.mono(13) : .system(size: 13))
            .foregroundStyle(WS.text)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.03)))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(focused ? WS.accent : WS.border, lineWidth: 1))
            .animation(.easeOut(duration: 0.15), value: focused)
    }
}

/// 设计稿 `Input type="password"`。
struct DarkSecureField: View {
    let placeholder: String
    @Binding var text: String

    @FocusState private var focused: Bool

    var body: some View {
        SecureField("", text: $text, prompt: Text(placeholder).foregroundStyle(WS.text4))
            .textFieldStyle(.plain)
            .focused($focused)
            .font(.system(size: 13))
            .foregroundStyle(WS.text)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.03)))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(focused ? WS.accent : WS.border, lineWidth: 1))
            .animation(.easeOut(duration: 0.15), value: focused)
    }
}

// MARK: - 分段控件

/// 设计稿 `Segmented`：选中项填 accent、白字；外裹微底 + 细描边。
struct DarkSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, label: String)]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.value) { opt in
                segment(opt.value, opt.label)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(WS.border, lineWidth: 1))
    }

    @ViewBuilder
    private func segment(_ value: Value, _ label: String) -> some View {
        let isOn = value == selection
        Button {
            selection = value
        } label: {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isOn ? Color.white : WS.text2)
                .padding(.horizontal, 14).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(isOn ? WS.accent : Color.clear))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 开关

/// 设计稿 `Switch`：32×18 胶囊，开 = accent，白色滑块。
struct DarkSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? WS.accent : Color.white.opacity(0.1))
                    .frame(width: 32, height: 18)
                Circle()
                    .fill(Color.white)
                    .frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
                    .padding(.horizontal, 2)
            }
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: isOn)
    }
}

// MARK: - section / field 布局

/// 设计稿 `FormSection`：uppercase 小标题 + 一道分隔线 + 右侧可选 slot（如开关）。
struct DarkFormSection<Trailing: View, Content: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(title.uppercased())
                    .font(.system(size: 10.5, weight: .medium))
                    .tracking(0.6)
                    .foregroundStyle(WS.text4)
                Rectangle().fill(WS.border).frame(height: 1)
                trailing
            }
            content
        }
    }
}

extension DarkFormSection where Trailing == EmptyView {
    init(title: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, trailing: { EmptyView() }, content: content)
    }
}

/// 设计稿 `FormField`：label（+ 可选灰色 hint）压在控件上方。
struct DarkFormField<Content: View>: View {
    let label: String
    var hint: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(WS.text2)
                if let hint {
                    Text(hint)
                        .font(.system(size: 11))
                        .foregroundStyle(WS.text4)
                }
            }
            content
        }
    }
}

// MARK: - 按钮

/// 设计稿 `Button`：primary = accent 填充 + 柔光阴影；secondary = 透明 + 描边。
struct DarkButton: View {
    let title: String
    var secondary: Bool = false
    var enabled: Bool = true
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(foreground)
                .padding(.horizontal, secondary ? 16 : 18)
                .frame(height: 32)
                .background(background)
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(secondary ? WS.border : Color.clear, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .shadow(color: (!secondary && enabled) ? WS.accent.opacity(0.45) : .clear,
                        radius: 7, y: 4)
                .brightness(hovering && enabled ? (secondary ? 0 : 0.08) : 0)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
    }

    private var foreground: Color {
        if secondary { return WS.text2 }
        return enabled ? .white : WS.text4
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: 7)
            .fill(secondary ? Color.clear
                  : (enabled ? WS.accent : Color.white.opacity(0.06)))
    }
}

// MARK: - 分组 chip

/// 设计稿分组 pill：选中态用 accent 微底 + accent 描边。
struct DarkChip: View {
    let label: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(selected ? WS.text : WS.text3)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(selected ? WS.accent.opacity(0.10) : Color.clear))
                .overlay(Capsule().strokeBorder(
                    selected ? WS.accent.opacity(0.4) : WS.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
