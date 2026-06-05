import SwiftUI

/// 按 `FileBuffer.kind` 路由到具体 body；无活动 buffer 时走空态。
/// Spec 2A §2.3。
struct PreviewBodyRouter: View {
    let model: FilePreviewModel

    var body: some View {
        Group {
            if let buf = model.activeBuffer {
                PreviewBufferBody(buffer: buf)
            } else {
                EmptyBody(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PreviewBufferBody: View {
    let buffer: FileBuffer

    var body: some View {
        Group {
            switch buffer.kind {
            case .code(let lang):
                CodeBody(buffer: buffer, language: LanguageDetector.grammarId(for: lang))
            case .markdown:
                MarkdownBody(buffer: buffer)
            case .image:
                ImageBody(buffer: buffer)
            case .plainText:
                CodeBody(buffer: buffer, language: "")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
