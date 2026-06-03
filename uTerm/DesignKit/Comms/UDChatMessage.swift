import SwiftUI

/// uTerm DesignKit 对话气泡原语合集 —— AI 助手 / 命令对话场景（设计稿
/// `Components.html` Comms & Chat）。
///
/// 纯展示组件：只读 `UD` token + 普通值输入，不依赖任何 domain model。
/// 一文件多原语：消息气泡 `UDChatMessage`、内联代码标签 `UDMonoTag`、
/// 块级代码片 `UDCodeChip`。气泡靠 `@Environment(\.colorScheme)` 区分深浅样式。

// MARK: - 对话气泡 ChatMessage

/// 单条对话消息。`user`（深=描边软底胶囊 / 浅=accent 实底）；
/// `assistant`（无气泡裸文本）。`streaming` 时尾随闪烁光标。
struct UDChatMessage<Content: View>: View {
    /// 消息角色。
    enum Role {
        case user, assistant
    }

    let role: Role
    let streaming: Bool
    let content: Content

    @Environment(\.colorScheme) private var scheme

    init(role: Role, streaming: Bool = false, @ViewBuilder content: () -> Content) {
        self.role = role
        self.streaming = streaming
        self.content = content()
    }

    private var isUser: Bool { role == .user }

    /// user 气泡文本色：浅色实底用白字，深色用 text2。
    private var bodyTextColor: Color {
        if isUser {
            return scheme == .light ? .white : UD.text2
        }
        return UD.text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(isUser ? "你" : "Claude")
                .font(UD.font(10.5))
                .tracking(0.4)
                .foregroundStyle(UD.text4)

            bodyContainer
        }
        .frame(width: 224, alignment: .leading)
    }

    @ViewBuilder
    private var bodyContainer: some View {
        let inner = HStack(alignment: .bottom, spacing: 3) {
            content
                .font(UD.font(12.5))
                .lineSpacing(3)
                .foregroundStyle(bodyTextColor)
            if streaming {
                UDStreamCaret()
            }
        }
        .fixedSize(horizontal: false, vertical: true)

        if isUser {
            inner
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .background(userBubbleBackground)
        } else {
            inner
        }
    }

    @ViewBuilder
    private var userBubbleBackground: some View {
        if scheme == .light {
            RoundedRectangle(cornerRadius: UD.Radius.lg, style: .continuous)
                .fill(UD.accent)
        } else {
            RoundedRectangle(cornerRadius: UD.Radius.lg, style: .continuous)
                .fill(UD.dyn(.white(0.035), .white(0.035)))
                .overlay(
                    RoundedRectangle(cornerRadius: UD.Radius.lg, style: .continuous)
                        .strokeBorder(UD.border, lineWidth: 1)
                )
        }
    }
}

// MARK: - 流式光标 StreamCaret

/// 流式回答尾随的闪烁光标（≈4×11 accent 方块，1↔0 透明度 ~1.1s 往复）。
private struct UDStreamCaret: View {
    @State private var on = true

    var body: some View {
        Rectangle()
            .fill(UD.accent)
            .frame(width: 4, height: 11)
            .opacity(on ? 1 : 0)
            .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true),
                       value: on)
            .onAppear { on = false }
    }
}

// MARK: - 内联代码标签 MonoTag

/// 内联等宽代码标签（如配置键名 `proxy_next_upstream_tries`）。低对比软底。
struct UDMonoTag: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(UD.mono(11.5))
            .foregroundStyle(UD.text)
            .padding(.vertical, 1)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(UD.dyn(.white(0.05), .black(0.05)))
            )
    }
}

// MARK: - 块级代码片 CodeChip

/// 块级等宽代码片（命令 / 片段）。终端底 + 描边，自动换行。
struct UDCodeChip: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(UD.mono(11.5))
            .foregroundStyle(UD.text2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: UD.Radius.sm, style: .continuous)
                    .fill(UD.terminal)
                    .overlay(
                        RoundedRectangle(cornerRadius: UD.Radius.sm, style: .continuous)
                            .strokeBorder(UD.border, lineWidth: 1)
                    )
            )
            .padding(.vertical, 6)
    }
}

#Preview {
    VStack(alignment: .leading, spacing: UD.Space.xxl) {
        UDChatMessage(role: .user) {
            Text("为什么 nginx 偶尔会 502？日志里看不出明显规律。")
        }

        UDChatMessage(role: .assistant) {
            VStack(alignment: .leading, spacing: 4) {
                Text("先确认上游是否短暂不可达。把完整配置导出来看 upstream 与 worker 设置：")
                UDCodeChip("nginx -T | grep -E \"worker|upstream\"")
                HStack(spacing: 3) {
                    Text("再留意")
                    UDMonoTag("proxy_next_upstream_tries")
                    Text("的取值。")
                }
            }
        }

        UDChatMessage(role: .assistant, streaming: true) {
            Text("正在分析最近一小时的 5xx 时间分布")
        }
    }
    .padding(UD.Space.xxxl)
    .background(UD.bg)
}
