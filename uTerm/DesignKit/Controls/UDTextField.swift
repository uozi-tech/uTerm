import SwiftUI

/// uTerm DesignKit 文本输入框 —— 可带标签 / 错误提示的单行输入。
///
/// 纯展示组件：仅持有外部传入的文本 `Binding`，不依赖任何 domain model。
/// 经由 `@Environment(\.isEnabled)` 响应 `.disabled()`。视觉状态优先级
/// 错误 > 聚焦 > 禁用 > 闲置。字段高 34，水平内边距 11，圆角 `UD.Radius.md`；
/// 标签 11 用 `UD.text3`，错误文案 10.5 用 `UD.danger`。聚焦 / 错误态各叠一圈
/// 3px 焦点环。
struct UDTextField: View {
    var label: String? = nil
    var placeholder: String
    @Binding var text: String
    var errorMessage: String? = nil
    var autoFocus: Bool = false
    var monospaced: Bool = false
    var isSecure: Bool = false

    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var focused: Bool

    init(label: String? = nil,
         placeholder: String,
         text: Binding<String>,
         errorMessage: String? = nil,
         autoFocus: Bool = false,
         monospaced: Bool = false,
         isSecure: Bool = false) {
        self.label = label
        self.placeholder = placeholder
        self._text = text
        self.errorMessage = errorMessage
        self.autoFocus = autoFocus
        self.monospaced = monospaced
        self.isSecure = isSecure
    }

    private var hasError: Bool { errorMessage != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let label {
                Text(label)
                    .font(UD.font(11))
                    .foregroundStyle(UD.text3)
            }

            field
                .textFieldStyle(.plain)
                .font(monospaced ? UD.mono(13) : UD.body)
                .foregroundStyle(UD.text)
                .focused($focused)
                .disabled(!isEnabled)
                .padding(.horizontal, 11)
                .frame(height: 34)
                .background(
                    RoundedRectangle(cornerRadius: UD.Radius.md)
                        .fill(fieldBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: UD.Radius.md)
                        .strokeBorder(borderColor, lineWidth: 1)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: UD.Radius.md)
                        .stroke(ringColor, lineWidth: 3)
                )
                .overlay(
                    UDInputFocusDismissMonitor(isFocused: $focused)
                )
                .opacity(isEnabled ? 1 : 0.55)
                .onAppear { focused = autoFocus }
                .onChange(of: autoFocus) { _, newValue in
                    focused = newValue
                }

            if let errorMessage {
                Text(errorMessage)
                    .font(UD.font(10.5))
                    .foregroundStyle(UD.danger)
            }
        }
    }

    @ViewBuilder
    private var field: some View {
        if isSecure {
            SecureField(placeholder, text: $text)
        } else {
            TextField(placeholder, text: $text)
        }
    }

    private var fieldBackground: Color {
        if !isEnabled {
            return UD.dyn(.white(0.015), .black(0.02))
        }
        return UD.dyn(.white(0.035), .hex(0xFFFFFF))
    }

    private var borderColor: Color {
        if hasError { return UD.danger }
        if focused { return UD.accent }
        return UD.dyn(.white(0.07), .black(0.16)) // UD.border (dark) / UD.borderHi (light)
    }

    private var ringColor: Color {
        if hasError { return UD.danger.opacity(0.12) }
        if focused { return UD.accent.opacity(0.13) }
        return Color.clear
    }
}

#Preview("UDTextField") {
    struct PreviewWrapper: View {
        @State private var idle = ""
        @State private var filled = "root@203.0.113.10"
        @State private var errored = "47.113"
        @State private var disabled = "root@203.0.113.10"

        var body: some View {
            HStack(alignment: .top, spacing: UD.Space.xxl) {
                UDTextField(label: "主机", placeholder: "user@host", text: $idle)
                    .frame(width: 240)
                UDTextField(label: "主机", placeholder: "user@host", text: $filled)
                    .frame(width: 240)
                UDTextField(label: "主机", placeholder: "user@host", text: $errored,
                            errorMessage: "无法解析该地址")
                    .frame(width: 240)
                UDTextField(label: "主机", placeholder: "user@host", text: $disabled)
                    .frame(width: 240)
                    .disabled(true)
            }
            .padding(UD.Space.xxxl)
            .background(UD.bg)
        }
    }
    return PreviewWrapper()
}
