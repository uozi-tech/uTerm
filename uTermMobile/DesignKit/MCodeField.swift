import SwiftUI

/// 定长数字码输入（配对码、验证码）：`length` 个格子显示每一位，背后只有一个隐藏的输入框。
///
/// 按 2FA 输入的通行做法：
/// - 一个真输入框驱动所有格子，粘贴整串、退格、听写、VoiceOver 都按一个字段工作，不用逐格切焦点；
/// - 数字键盘，只收 ASCII 数字、最多 `length` 位（粘贴「123 456」或带别的字符也只取数字）；
/// - 当前位描 accent 边，已填的位显示数字；点格子区域任意处都能唤起键盘；
/// - 填满即回调 `onComplete`，由调用方保存并收起，不需要再点「保存」。
struct MCodeField: View {
    @Binding var code: String
    var length: Int = 6
    var onComplete: (String) -> Void = { _ in }

    @Environment(\.mAccent) private var accent
    @FocusState private var focused: Bool

    /// 只留数字、截到 `length` 位（规则在两端共用的 `CodeFieldInput`）。
    nonisolated static func normalize(_ text: String, length: Int) -> String {
        CodeFieldInput.normalize(text, length: length)
    }

    var body: some View {
        ZStack {
            TextField("", text: $code)
                .keyboardType(.numberPad)
                // 不设 .oneTimeCode：配对码来自 Mac 屏幕而不是短信，键盘会推荐不相干的短信验证码。
                .focused($focused)
                // 不可见但可交互：真正的输入落在这里，格子只负责显示。
                .opacity(0.01)
                .frame(width: 1, height: 1)
                .accessibilityHidden(true)

            HStack(spacing: 10) {
                ForEach(0..<length, id: \.self) { index in cell(index) }
            }
            .contentShape(Rectangle())
            .onTapGesture { focused = true }
        }
        .onChange(of: code) { _, value in
            let normalized = Self.normalize(value, length: length)
            if normalized != value { code = normalized; return }
            if normalized.count == length { onComplete(normalized) }
        }
        .onAppear { focused = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(length) 位数字码"))
        .accessibilityValue(Text(code.isEmpty ? "未输入" : CodeFieldInput.spoken(code)))
        .accessibilityAction { focused = true }
    }

    private func cell(_ index: Int) -> some View {
        let digits = Array(code)
        let digit = index < digits.count ? String(digits[index]) : ""
        // 当前位 = 下一个要输入的位；填满后高亮最后一位。
        let isCurrent = focused && index == min(digits.count, length - 1)
        return Text(digit)
            .font(M.mono(24, weight: .semibold))
            .foregroundStyle(M.text)
            .frame(width: 44, height: 54)
            .background(M.card, in: RoundedRectangle(cornerRadius: MRadius.lg, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: MRadius.lg, style: .continuous)
                    .strokeBorder(isCurrent ? accent : M.divider, lineWidth: isCurrent ? 2 : 1)
            }
            .animation(.easeOut(duration: 0.12), value: isCurrent)
    }
}
