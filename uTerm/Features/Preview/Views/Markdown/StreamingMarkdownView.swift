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

    @State private var renderer = StreamingMarkdownRenderer()

    var body: some View {
        MarkdownBlocks(
            document: renderer.document,
            style: style,
            imageLoader: imageLoader,
            isStreaming: isStreaming)
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

/// 保存节流窗口内的最新 source，而不是让 `DispatchWorkItem` 捕获安排任务时的旧 View
/// 值。定时器触发时总是解析 `latestSource`；流落定时则立即冲掉最终文本。
@MainActor
@Observable
final class StreamingMarkdownRenderer {
    static let reparseDelay: Duration = .milliseconds(100)

    private(set) var document: Document
    private(set) var renderedSource: String

    @ObservationIgnored private let reparseDelay: Duration
    @ObservationIgnored private var latestSource: String
    @ObservationIgnored private var pendingReparse: Task<Void, Never>?

    init(reparseDelay: Duration = StreamingMarkdownRenderer.reparseDelay) {
        self.reparseDelay = reparseDelay
        self.latestSource = ""
        self.renderedSource = ""
        self.document = Document(parsing: "")
    }

    func renderImmediately(_ source: String) {
        latestSource = source
        pendingReparse?.cancel()
        pendingReparse = nil
        renderLatest()
    }

    func update(_ source: String, isStreaming: Bool) {
        latestSource = source
        guard isStreaming else {
            renderImmediately(source)
            return
        }
        guard latestSource != renderedSource, pendingReparse == nil else { return }
        let reparseDelay = reparseDelay
        pendingReparse = Task { [weak self] in
            do {
                try await Task.sleep(for: reparseDelay)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.pendingReparse = nil
            self.renderLatest()
        }
    }

    func cancel() {
        pendingReparse?.cancel()
        pendingReparse = nil
    }

    private func renderLatest() {
        guard latestSource != renderedSource else { return }
        renderedSource = latestSource
        document = Document(parsing: latestSource)
    }
}
