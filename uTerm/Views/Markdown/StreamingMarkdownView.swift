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

    @State private var renderedSource: String = ""
    @State private var document: Document = Document(parsing: "")
    @State private var pendingWork: DispatchWorkItem?

    var body: some View {
        MarkdownBlocks(document: document, style: style, isStreaming: isStreaming)
            .onAppear { reparse(force: true) }
            .onChange(of: text) { _, _ in scheduleReparse() }
            .onChange(of: isStreaming) { _, streaming in
                if !streaming {
                    pendingWork?.cancel(); pendingWork = nil
                    reparse(force: true)   // 落定：取消在途节流，立即最终解析
                }
            }
            .onDisappear { pendingWork?.cancel(); pendingWork = nil }
    }

    private func scheduleReparse() {
        guard isStreaming else { reparse(force: true); return }
        guard pendingWork == nil else { return }   // 节流窗口内已排队
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                pendingWork = nil
                reparse(force: false)
            }
        }
        pendingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    private func reparse(force: Bool) {
        guard force || text != renderedSource else { return }
        renderedSource = text
        document = Document(parsing: text)
    }
}
