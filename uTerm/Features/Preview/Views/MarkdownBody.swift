import SwiftUI
import UDesignKit

/// Markdown 看哪一面：渲染好的预览，或者源码（编辑）。二选一，记住上次选的（所有 Markdown 标签共用一个设置）。
nonisolated enum MarkdownViewMode: String, CaseIterable, Sendable {
    case preview
    case source

    /// 没选过、或存着认不出的值：预览（点开 Markdown 多半是要看）。
    static func stored(_ raw: String?) -> MarkdownViewMode { raw.flatMap(Self.init(rawValue:)) ?? .preview }
}

/// Markdown body：顶上一条切换，下面是预览（`MarkdownRenderer`）或源码（`CodeBody`，能改、自动保存）。
struct MarkdownBody: View {
    let buffer: FileBuffer
    var imageLoader: MarkdownImageLoader?

    @AppStorage(DefaultsKey.markdownViewMode) private var storedMode = MarkdownViewMode.preview.rawValue

    private var mode: Binding<MarkdownViewMode> {
        Binding(get: { MarkdownViewMode.stored(storedMode) }, set: { storedMode = $0.rawValue })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer(minLength: 0)
                UDSegmented(selection: mode, options: [
                    (value: MarkdownViewMode.preview, label: String(localized: "预览")),
                    (value: MarkdownViewMode.source, label: String(localized: "编辑")),
                ])
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .overlay(alignment: .bottom) { Rectangle().fill(UD.border).frame(height: 1) }

            switch mode.wrappedValue {
            case .preview:
                MarkdownRenderer(source: buffer.text, imageLoader: imageLoader)
                    .padding(.horizontal, 16).padding(.vertical, 10)
            case .source:
                CodeBody(buffer: buffer, language: "markdown")
            }
        }
        .background(Color(nsColor: EditorTheme.background))
    }
}
