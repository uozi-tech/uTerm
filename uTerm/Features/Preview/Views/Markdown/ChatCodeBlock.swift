import UDesignKit
// uTerm/Views/Markdown/ChatCodeBlock.swift
import SwiftUI
import AppKit

/// 聊天代码块：顶栏（语言名 + 复制）+ 高亮正文。
/// 流式中只渲染纯等宽（不跑高亮），落定后做一次高亮，避免每 token 重 parse。
struct ChatCodeBlock: View {
    static let containerCornerRadius = UD.Radius.lg

    let code: String
    let language: String?
    let isStreaming: Bool
    let style: MarkdownStyle

    @State private var copied = false
    /// 整块一个 `onHover`：既门控 tooltip，也让复制钮的按压反馈有处可依。
    @State private var isHovering = false

    private var trimmed: String { code.trimmingCharacters(in: .newlines) }
    private var containerShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Self.containerCornerRadius, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            content
        }
        .background(containerShape.fill(style.codeBlockBackground))
        .clipShape(containerShape)
        .overlay(containerShape.strokeBorder(style.border, lineWidth: 1))
        .onHover { isHovering = $0 }
    }

    /// 复制钮**保持 `Button`**。试过按 uTable playbook §四 第 2 层把它换成
    /// `onTapGesture` + 手工 AX，同轮读数是反的（`docs/scroll-perf-findings.md`
    /// 「Agent 消息流」§反例）：`Button` 一去，命中不再早早落在真控件上，
    /// hitTest p50 473 → 664µs；而且整棵消息树套着 `.textSelection(.enabled)`，
    /// 「复制」两个字从按钮标签变成可选文本后，每个代码块反而多长出一个
    /// `SelectionTextField`（803 → 817 个 NSView）。留下的只有 tooltip 那一半。
    private var header: some View {
        HStack {
            Text(language?.isEmpty == false ? language! : "code")
                .font(.system(size: 10.5))
                .foregroundStyle(style.textMuted)
            Spacer()
            Button(action: copy) {
                HStack(spacing: 4) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    Text(copied ? "已拷贝" : "拷贝")
                }
                .font(.system(size: 10.5))
                .foregroundStyle(copied ? UD.success : style.textMuted)
            }
            .buttonStyle(.udPlain)
            .accessibilityLabel(copied ? "已拷贝代码" : "拷贝代码")
            // tooltip 走悬停门控：`NSToolTipManager` 每个滚动 tick 都要全量重算
            // 全窗的 tooltip 区域，一条回复里七八个代码块就是七八块常驻区域。
            .help(whenHovering: isHovering, "拷贝代码")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { Rectangle().fill(style.border).frame(height: 1) }
    }

    private func copy() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(trimmed, forType: .string)
        copied = true
        AccessibilityNotification.Announcement("已拷贝代码").post()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            copied = false
        }
    }

    @ViewBuilder
    private var content: some View {
        ScrollView(.horizontal) {
            Group {
                if isStreaming {
                    Text(trimmed)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(style.textPrimary)
                } else {
                    Text(CodeHighlighter.attributed(code: trimmed, language: language))
                }
            }
            // 代码和预格式化诊断依赖列对齐；窄侧边栏中应横向滚动，不应把行尾
            // emoji 折到下一行。
            .fixedSize(horizontal: true, vertical: false)
            .textSelection(.enabled)
            .padding(10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
