import SwiftUI

/// uTerm DesignKit 对话输入区 —— 设计稿 `Components.html` Comms 组。
///
/// `UDComposer` 是一块约 300 宽的聊天输入框：纵向 `TextField`（1...5 行）在上，
/// 底栏左侧一枚 24×24 附件钮、右侧一枚内联回车 chip + 「发送」标签。
/// 纯展示组件，只读 `UD` token + 普通值/闭包输入，不依赖任何 domain model。
struct UDComposer: View {
    @Binding var text: String
    var placeholder: String = "问点什么…"
    var onSend: () -> Void = {}
    var onAttach: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(UD.font(12))
                .foregroundStyle(UD.text)
                .lineLimit(1...5)

            HStack(spacing: 6) {
                Button(action: onAttach) {
                    Image(systemName: "plus")
                }
                .buttonStyle(UDComposerAttachStyle())

                Spacer(minLength: 0)

                Button(action: onSend) {
                    Text("↩")
                        .font(UD.mono(10.5))
                        .foregroundStyle(UD.text2)
                        .frame(minWidth: 18, minHeight: 20)
                        .padding(.horizontal, 5)
                        .frame(height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: UD.Radius.xs, style: .continuous)
                                .fill(UD.dyn(.white(0.04), .black(0.04)))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: UD.Radius.xs, style: .continuous)
                                .strokeBorder(UD.border, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)

                Text("发送")
                    .font(UD.font(10.5))
                    .foregroundStyle(UD.text4)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(width: 300)
        .background(
            RoundedRectangle(cornerRadius: UD.Radius.lg, style: .continuous)
                .fill(UD.dyn(.white(0.025), .black(0.025)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: UD.Radius.lg, style: .continuous)
                .strokeBorder(UD.border, lineWidth: 1)
        )
    }
}

// MARK: - 附件钮样式（24×24，hover 底 UD.panelHover）

private struct UDComposerAttachStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(UD.font(11))
            .foregroundStyle(UD.text3)
            .frame(width: 24, height: 24)
            .background(
                RoundedRectangle(cornerRadius: UD.Radius.sm, style: .continuous)
                    .fill(hovering ? UD.panelHover : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: UD.Radius.sm, style: .continuous)
                    .strokeBorder(UD.border, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: UD.Radius.sm, style: .continuous))
            .onHover { hovering = $0 }
    }
}

// MARK: - Preview

#Preview {
    struct Wrapper: View {
        @State private var empty = ""
        @State private var filled = "帮我把这台机器的 nginx 配置检查一下，看看有没有明显的安全问题。"

        var body: some View {
            VStack(alignment: .leading, spacing: 24) {
                UDComposer(text: $empty)
                UDComposer(text: $filled)
            }
            .padding(32)
            .background(UD.bg)
        }
    }
    return Wrapper()
}
