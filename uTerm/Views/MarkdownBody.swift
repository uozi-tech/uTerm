import SwiftUI

/// Markdown body：左 CodeBody（源码） / 右 MarkdownRenderer（渲染）。
struct MarkdownBody: View {
    let buffer: FileBuffer
    var body: some View {
        HSplitView {
            CodeBody(buffer: buffer, language: "markdown")
                .frame(minWidth: 280, idealWidth: 480)
            MarkdownRenderer(source: buffer.text)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .frame(minWidth: 280, idealWidth: 480)
                .background(AppTheme.Palette.bgBase)
        }
    }
}
