import SwiftUI

/// 按 `FileBuffer.kind` 路由到具体 body；无活动 buffer 时走空态。
/// Spec 2A §2.3。
struct PreviewBodyRouter: View {
    let model: FilePreviewModel

    var body: some View {
        Group {
            if let buf = model.activeBuffer {
                switch buf.kind {
                case .code(let lang):
                    CodeBody(buffer: buf, language: LanguageDetector.grammarId(for: lang))
                case .markdown:
                    MarkdownBody(buffer: buf)
                case .image:
                    ImageBody(buffer: buf)
                case .plainText:
                    CodeBody(buffer: buf, language: "")
                }
            } else {
                EmptyBody(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
