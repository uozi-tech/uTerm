// uTerm/Views/Markdown/ChatCodeBlock.swift
import SwiftUI
import AppKit

/// 聊天代码块：顶栏（语言名 + 复制）+ 高亮正文。
/// 流式中只渲染纯等宽（不跑高亮），落定后做一次高亮，避免每 token 重 parse。
struct ChatCodeBlock: View {
    let code: String
    let language: String?
    let isStreaming: Bool
    let style: MarkdownStyle

    @State private var copied = false

    private var trimmed: String { code.trimmingCharacters(in: .newlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            content
        }
        .background(WS.terminal)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(style.border, lineWidth: 1))
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
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    copied = false
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    Text(copied ? "已复制" : "复制")
                }
                .font(.system(size: 10.5))
                .foregroundStyle(copied ? WS.connected : style.textMuted)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { Rectangle().fill(style.border).frame(height: 1) }
    }

    @ViewBuilder
    private var content: some View {
        Group {
            if isStreaming {
                Text(trimmed)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(style.textPrimary)
            } else {
                Text(CodeHighlighter.attributed(code: trimmed, language: language))
            }
        }
        .textSelection(.enabled)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
