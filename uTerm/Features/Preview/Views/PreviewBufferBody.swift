import UDesignKit
import SwiftUI
import AppKit

/// 按 `FileBuffer.kind` 路由到具体 body。
///
/// 改造前这个文件里还有一个 `PreviewBodyRouter`（「没有面板树时画单文件正文，
/// 否则画空态」）—— 组模型下永远有组，空组由 `UPaneGroupArea` 的 `emptyGroup`
/// 闭包画「最近打开」，那层路由没有存在意义了。
struct PreviewBufferBody: View {
    let buffer: FileBuffer
    /// 编辑器焦点请求（透传给 CodeBody → CodeEditorView 消费）。
    var focusRequest: EditorFocusRequest? = nil
    var onDownload: ((FileBuffer, URL) async throws -> Void)?
    let onLoadMarkdownImage: MarkdownBufferImageLoader

    var body: some View {
        Group {
            switch buffer.state {
            case .loading:
                PreviewLoadingBody()
            case .failed(let message):
                PreviewUnavailableBody(
                    buffer: buffer,
                    title: "无法预览此文件",
                    message: message,
                    onDownload: onDownload)
            case .loaded, .saving:
                previewContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var previewContent: some View {
        switch buffer.kind {
        case .code(let lang):
            CodeBody(buffer: buffer, language: LanguageDetector.grammarId(for: lang),
                     focusRequest: focusRequest)
        case .markdown:
            MarkdownBody(buffer: buffer, imageLoader: markdownImageLoader)
        case .image:
            ImageBody(buffer: buffer)
        case .plainText:
            CodeBody(buffer: buffer, language: "", focusRequest: focusRequest)
        }
    }

    private var markdownImageLoader: MarkdownImageLoader? {
        return { source in
            try await onLoadMarkdownImage(source, buffer)
        }
    }
}

private struct PreviewLoadingBody: View {
    var body: some View {
        VStack(spacing: 10) {
            UDIndeterminateBar()
                .frame(width: 140)
            Text("正在检查文件…")
                .font(UD.caption)
                .foregroundStyle(UD.text3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: EditorTheme.background))
    }
}

private struct PreviewUnavailableBody: View {
    let buffer: FileBuffer
    let title: String
    let message: String
    let onDownload: ((FileBuffer, URL) async throws -> Void)?

    @State private var isDownloading = false
    @State private var downloadError: String?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.badge.exclamationmark")
                .font(.system(size: 34))
                .foregroundStyle(UD.text3)
            Text(title)
                .font(.headline)
                .foregroundStyle(UD.text)
            Text(message)
                .font(UD.body)
                .foregroundStyle(UD.text3)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 460)
            Text(buffer.remotePath)
                .font(UD.mono(11))
                .foregroundStyle(UD.text4)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: 520)

            if let byteSize = buffer.byteSize, byteSize > 0 {
                Text(UFormat.bytes(byteSize))
                    .font(UD.mono(10.5))
                    .foregroundStyle(UD.text4)
            }

            UDButton(title: isDownloading ? "下载中…" : "下载…",
                     style: .secondary,
                     systemImage: "arrow.down.circle") {
                Task { await download() }
            }
            .disabled(onDownload == nil || isDownloading)

            if let downloadError {
                Text(downloadError)
                    .font(UD.caption)
                    .foregroundStyle(UD.danger)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .frame(maxWidth: 460)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: EditorTheme.background))
    }

    @MainActor
    private func download() async {
        guard let onDownload else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = buffer.displayName
        guard panel.runModal() == .OK, let url = panel.url else { return }

        isDownloading = true
        downloadError = nil
        defer { isDownloading = false }

        do {
            try await onDownload(buffer, url)
        } catch {
            downloadError = "下载失败：\(FriendlyError.describe(error))"
        }
    }
}
