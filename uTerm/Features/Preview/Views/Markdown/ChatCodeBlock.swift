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
    }

    private var header: some View {
        HStack {
            Text(language?.isEmpty == false ? language! : "code")
                .font(.system(size: 10.5))
                .foregroundStyle(style.textMuted)
            Spacer()
            Button {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(trimmed, forType: .string)
                copied = true
                AccessibilityNotification.Announcement("已复制代码").post()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    copied = false
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    Text(copied ? "已复制" : "复制")
                }
                .font(.system(size: 10.5))
                .foregroundStyle(copied ? UD.success : style.textMuted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(copied ? "已复制代码" : "复制代码")
            .help("复制代码")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { Rectangle().fill(style.border).frame(height: 1) }
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
