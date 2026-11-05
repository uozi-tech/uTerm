// uTerm/Views/Markdown/StreamingMarkdownView.swift
import SwiftUI
import Markdown

/// 聊天助手消息的流式 Markdown 渲染。
/// - 流式中：最多每 ~100ms 重解析一次，降低高频重建。
/// - 流式结束：立即最终解析，保证落定结果完整正确。
struct StreamingMarkdownView: View {
    let text: String
    let isStreaming: Bool
    var style: MarkdownStyle = .chat
    var imageLoader: MarkdownImageLoader?
    /// 分段渲染的一段大小（见 `MarkdownBlockWindow`）；聊天皮肤不分段。
    var maxBlocks: Int = .max
    var moreBlocks: ((Int) -> AnyView)?

    /// 节流器与 iOS 共用（`StreamingMarkdownRenderer.swift`），macOS 用默认值：固定 100ms、不缓存。
    @State private var renderer = StreamingMarkdownRenderer()

    var body: some View {
        MarkdownBlocks(
            document: renderer.document,
            style: style,
            imageLoader: imageLoader,
            isStreaming: isStreaming,
            maxBlocks: maxBlocks,
            moreBlocks: moreBlocks)
            .onAppear { renderer.renderImmediately(text) }
            .onChange(of: text) { _, newText in
                renderer.update(newText, isStreaming: isStreaming)
            }
            .onChange(of: isStreaming) { _, streaming in
                renderer.update(text, isStreaming: streaming)
            }
            .onDisappear { renderer.cancel() }
    }
}
