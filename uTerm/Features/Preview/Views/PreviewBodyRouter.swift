import UDesignKit
import SwiftUI
import AppKit

/// 按 `FileBuffer.kind` 路由到具体 body；无活动 buffer 时走空态。
/// Spec 2A §2.3。
struct PreviewBodyRouter: View {
    let model: FilePreviewModel

    var body: some View {
        Group {
            if let buf = model.activeBuffer {
                PreviewBufferBody(buffer: buf, onDownload: { buffer in
                    try await model.download(buffer)
                }, onLoadMarkdownImage: { source, buffer in
                    try await model.loadMarkdownImage(source: source, referencedBy: buffer)
                })
            } else {
                EmptyBody(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PreviewBufferBody: View {
    let buffer: FileBuffer
    var onDownload: ((FileBuffer) async throws -> Data)?
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
            CodeBody(buffer: buffer, language: LanguageDetector.grammarId(for: lang))
        case .markdown:
            MarkdownBody(buffer: buffer, imageLoader: markdownImageLoader)
        case .image:
            ImageBody(buffer: buffer)
        case .plainText:
            CodeBody(buffer: buffer, language: "")
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
    let onDownload: ((FileBuffer) async throws -> Data)?

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

            if buffer.byteSize > 0 {
                Text(ByteCountFormatter.string(fromByteCount: buffer.byteSize, countStyle: .file))
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
            let data = try await onDownload(buffer)
            try await Task.detached(priority: .userInitiated) {
                try data.write(to: url)
            }.value
        } catch {
            downloadError = "下载失败：\(FriendlyError.describe(error))"
        }
    }
}
