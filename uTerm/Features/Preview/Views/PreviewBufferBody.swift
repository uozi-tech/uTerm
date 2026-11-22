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
    let onLoadMarkdownImage: MarkdownBufferImageLoader

    var body: some View {
        Group {
            switch buffer.state {
            case .loading:
                PreviewLoadingBody()
            case .failed(let message):
                PreviewUnavailableBody(
                    buffer: buffer,
                    title: String(localized: "无法预览此文件"),
                    message: message)
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

/// 不能预览的文件：只剩「打开 / 打开方式 ▸ / 下载…」（叫法见 `RemoteFileAction`），
/// 经 `.remoteFileCommand` 交给所在窗口执行——下载进状态栏的传输 Dock，与右键下载同一条队列。
private struct PreviewUnavailableBody: View {
    let buffer: FileBuffer
    let title: String
    let message: String

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

            HStack(spacing: 8) {
                UDButton(title: RemoteFileAction.open.title, style: .primary,
                         systemImage: RemoteFileAction.open.systemImage) {
                    RemoteFileCommand.open(path: buffer.remotePath, route: .preferred).post()
                }
                .help(RemoteFileAction.open.help)
                OpenWithMenuButton(path: buffer.remotePath) { route in
                    RemoteFileCommand.open(path: buffer.remotePath, route: route).post()
                }
                .help(RemoteFileAction.openWith.help)
                UDButton(title: RemoteFileAction.download.title, style: .secondary,
                         systemImage: RemoteFileAction.download.systemImage) {
                    RemoteFileCommand.download(path: buffer.remotePath, size: buffer.byteSize).post()
                }
                .help(RemoteFileAction.download.help)
            }

            Text(OpenWithChoices.openTargetDescription(forPath: buffer.remotePath))
                .font(UD.caption)
                .foregroundStyle(UD.text4)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: EditorTheme.background))
    }
}
