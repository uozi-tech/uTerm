// uTerm/Preview/MarkdownRenderer.swift
import SwiftUI
import Markdown

typealias MarkdownImageLoader = @MainActor (String) async throws -> Data
typealias MarkdownBufferImageLoader = @MainActor (String, FileBuffer) async throws -> Data

/// 把 Markdown 源码渲染为 SwiftUI 视图（文件预览侧；跟随系统外观）。
/// 渲染逻辑在 `MarkdownBlocks`，此处仅包 ScrollView + .preview 皮肤。
struct MarkdownRenderer: View {
    let source: String
    var imageLoader: MarkdownImageLoader?

    var body: some View {
        ScrollView {
            MarkdownBlocks(document: Document(parsing: source),
                           style: .preview,
                           imageLoader: imageLoader)
                .padding(.vertical, 4)
        }
    }
}
