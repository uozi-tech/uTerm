import SwiftUI

enum UDComposerLayout {
    /// 输入框内容到圆角边框的四周内边距，保持上下左右一致。
    nonisolated static let contentPadding: CGFloat = UD.Space.lg
}

/// uTerm DesignKit 对话输入区 —— 设计稿 `workspace.jsx` Agent 输入区（Cursor 风格）。
///
/// `UDComposer` 是一块约 300 宽的聊天输入框：纵向 `TextField`（1...5 行）在上，
/// 底栏 Cursor 式三件套——左侧模型控件槽 `modelControl`（通常是 `● <模型> ▾` 胶囊，
/// 真实面板里包一层 `Menu`），右侧附件钮 + ↩ 发送钮（皆 28²）。
/// 模型槽为泛型，省略时退化为 `EmptyView`（底栏只剩右侧两钮）。
/// 纯展示组件，只读 `UD` token + 普通值 / 闭包 / 视图输入，不依赖任何 domain model。
struct UDComposer<ModelControl: View>: View {
    @Binding var text: String
    var placeholder: String = "问点什么…"
    /// 固定宽度（DesignKit 画廊用 300 spec）；`nil` 则撑满容器（真实 Agent 面板用）。
    var width: CGFloat? = nil
    /// 输入框最少显示行数（默认 1；真实 Agent 面板传更大值让输入区更高）。
    var minLines: Int = 1
    /// Agent 忙碌时为 true：发送钮变「排队」形态（提交即入队而非直发）。
    var queueing: Bool = false
    var onSend: () -> Void = {}
    var onAttach: () -> Void = {}
    @ViewBuilder var modelControl: () -> ModelControl

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(UD.font(12))
                .foregroundStyle(UD.text)
                .lineLimit(minLines...max(minLines + 4, 8))
                .submitLabel(.send)
                .onSubmit(submit)

            HStack(spacing: 6) {
                modelControl()

                Spacer(minLength: 0)

                Button(action: onAttach) {
                    Image(systemName: "plus")
                }
                .buttonStyle(UDComposerIconStyle())
                .help("附加上下文")

                Button(action: submit) {
                    Text(queueing ? "⊕" : "↩")
                        .font(UD.font(12))
                }
                .buttonStyle(UDComposerIconStyle())
                .help(queueing ? "排队发送（Agent 忙碌中）" : "发送")
            }
        }
        .padding(UDComposerLayout.contentPadding)
        .frame(width: width)
        .frame(maxWidth: width == nil ? .infinity : nil)
        .background(
            RoundedRectangle(cornerRadius: UD.Radius.lg, style: .continuous)
                .fill(UD.inputBg)   // 日间纯白底 / 暗夜白叠加细底
        )
        .overlay(
            RoundedRectangle(cornerRadius: UD.Radius.lg, style: .continuous)
                .strokeBorder(UD.border, lineWidth: 1)
        )
    }

    private func submit() {
        onSend()
    }
}

// MARK: - 无模型槽的便捷初始化（底栏只剩附件 + 发送）

extension UDComposer where ModelControl == EmptyView {
    init(text: Binding<String>,
         placeholder: String = "问点什么…",
         width: CGFloat? = nil,
         minLines: Int = 1,
         queueing: Bool = false,
         onSend: @escaping () -> Void = {},
         onAttach: @escaping () -> Void = {}) {
        self.init(text: text,
                  placeholder: placeholder,
                  width: width,
                  minLines: minLines,
                  queueing: queueing,
                  onSend: onSend,
                  onAttach: onAttach,
                  modelControl: { EmptyView() })
    }
}

// MARK: - 模型胶囊 ModelPill（● <模型> ▾）

/// 模型胶囊的视觉内容（`● <label> ▾`），无交互，供 `Button` / `Menu` 复用 label，
/// 保证 DesignKit 与真实 Agent 面板的模型选择器外观一致。
struct UDModelPillLabel: View {
    let label: String

    init(_ label: String) {
        self.label = label
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(UD.accent)
                .frame(width: 5, height: 5)
            Text(label)
                .font(UD.font(11.5))
                .foregroundStyle(UD.text2)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(UD.text4)
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(UD.dyn(.white(0.02), .hex(0xFFFFFF)))   // 日间 = UDInput 的白（纯白 + 描边）
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(UD.border, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

/// 模型选择胶囊按钮。点击触发 `action`（真实面板可换成 `Menu` 包裹 `UDModelPillLabel`）。
struct UDModelPill: View {
    let label: String
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            UDModelPillLabel(label)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 底栏图标钮样式（28×28，圆角 7，hover 底 UD.panelHover）

private struct UDComposerIconStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(UD.font(12))
            .foregroundStyle(UD.text3)
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hovering ? UD.panelHover : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(UD.border, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
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
                UDComposer(text: $empty, width: 300) { UDModelPill(label: "claude-sonnet") }
                UDComposer(text: $filled, width: 300) { UDModelPill(label: "gpt-4o") }
                UDComposer(text: $empty, width: 300)
            }
            .padding(32)
            .background(UD.bg)
        }
    }
    return Wrapper()
}
