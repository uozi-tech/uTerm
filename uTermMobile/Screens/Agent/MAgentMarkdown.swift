import SwiftUI
import UIKit
import Markdown

/// Agent 助手消息的 Markdown 渲染（移动端）。
///
/// 复用 macOS 的**同一套 swift-markdown 解析 + 分块渲染逻辑**（见
/// `uTerm/Features/Preview/Views/Markdown/*`：`StreamingMarkdownView` / `MarkdownBlocks` /
/// `ChatCodeBlock`），但落地改用移动端 `M` 设计 token 与 UIKit（`UIPasteboard`）——
/// macOS 那套深绑 AppKit（`NSPasteboard` / `NSImage` / `Color(nsColor:)`）与 `UD` token，
/// 无法直接进 iOS target，故按本仓「共享后端、各端自绘 UI」的惯例镜像一份。
///
/// 与 macOS 的取舍差异：代码块走**纯等宽**（不引入仅 macOS 的 CodeHighlighter / tree-sitter，
/// 它们已在移动端 target 排除），与 macOS 流式态的渲染一致；图片默认按 alt 文本内联（聊天不做
/// 远端图片加载）。文档预览经环境放进 `MMarkdownImageLoader`，只有一张图的段落就画成图。

// MARK: - 流式渲染包装

/// 流式 Markdown：流式中按长度降频重解析；落定后立即最终解析。
/// 节流器与 macOS `StreamingMarkdownView` 共用 `StreamingMarkdownRenderer`，这里打开两个 iOS 选项：
///  - 节流间隔随文本长度放大（几十 KB 的长回复按固定 100ms 整段重解析会占掉主线程一大块）；
///  - 落定消息的解析结果按全文缓存（懒栈回收后再出现会重新 `onAppear`，命中缓存就不用重解析）。
///
/// 节流窗口里解析的是 renderer 存着的最新文本：改前定时任务捕获的是排队时的旧 View 值，
/// 流式中一直落后一个窗口。
struct MStreamingMarkdown: View {
    let text: String
    let isStreaming: Bool

    @State private var renderer = StreamingMarkdownRenderer(scalesDelayWithLength: true,
                                                            settledCache: .shared)

    var body: some View {
        MMarkdownBlocks(document: renderer.document, isStreaming: isStreaming)
            .onAppear { renderer.renderImmediately(text, isStreaming: isStreaming) }
            .onChange(of: text) { _, newText in
                renderer.update(newText, isStreaming: isStreaming)
            }
            .onChange(of: isStreaming) { _, streaming in
                renderer.update(text, isStreaming: streaming)
            }
            .onDisappear { renderer.cancel() }
    }
}

// MARK: - 图片

/// 给 Markdown 读图的人（文档预览标签：读同一台主机上的文件）。没有时图片按替代文字内联。
struct MMarkdownImageLoader {
    let load: @MainActor (String) async throws -> UIImage
}

extension EnvironmentValues {
    @Entry var mMarkdownImageLoader: MMarkdownImageLoader? = nil
}

private struct MMDImageView: View {
    let source: String
    let alt: String
    let loader: MMarkdownImageLoader
    /// 包着这张图的链接：点图打开。只认网址（`TerminalLink`）——文档是主机上的，里面的链接谁都能写。
    var link: String? = nil
    /// 和别的图排在一行时限一个宽度（行布局按理想尺寸排，不限的话大图会撑出屏幕）；单独一张时铺满可用宽度为止。
    var maxWidthInRow: CGFloat? = nil

    private enum Phase { case loading, loaded(UIImage), failed }
    @State private var phase = Phase.loading

    var body: some View {
        Group {
            switch phase {
            case .loading:
                ProgressView()
                    .frame(minWidth: 44, maxWidth: maxWidthInRow == nil ? .infinity : 44, minHeight: 44)
            case .loaded(let image):
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .modifier(MMDImageSizing(natural: image.size, maxWidthInRow: maxWidthInRow))
                    .clipShape(RoundedRectangle(cornerRadius: MRadius.xs))
                    .accessibilityLabel(Text(verbatim: alt.isEmpty ? source : alt))
            case .failed:
                Label {
                    Text(verbatim: alt.isEmpty ? source : alt)
                } icon: {
                    Image(systemName: "photo")
                }
                .font(M.sans(13))
                .foregroundStyle(M.text3)
            }
        }
        .frame(maxWidth: maxWidthInRow == nil ? .infinity : nil, alignment: .leading)
        .modifier(MMDImageLink(link: link))
        .task(id: source) {
            phase = .loading
            do {
                phase = .loaded(try await loader.load(source))
            } catch {
                phase = .failed
            }
        }
    }
}

/// 图外面包着网址链接：整张图可点，点了交给系统打开（同正文里的链接）。
private struct MMDImageLink: ViewModifier {
    let link: String?
    @Environment(\.openURL) private var openURL

    private var url: URL? {
        guard let link, case .web = TerminalLink.classify(link) else { return nil }
        return URL(string: link)
    }

    func body(content: Content) -> some View {
        if let url {
            Button { openURL(url) } label: { content }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isLink)
        } else {
            content
        }
    }
}

/// 单独一张：不放大，宽不超过可用宽度（宽度由外面给）。排在一行里：外面不给宽度，按比例算出确切的宽高，
/// 否则缩窄后的图还占着原来的高度、上下留白。
private struct MMDImageSizing: ViewModifier {
    let natural: CGSize
    let maxWidthInRow: CGFloat?

    func body(content: Content) -> some View {
        if let cap = maxWidthInRow, natural.width > 0 {
            let width = min(natural.width, cap)
            content.frame(width: width, height: natural.height * width / natural.width)
        } else {
            content.frame(maxWidth: natural.width, alignment: .leading)
        }
    }
}

// MARK: - 分块渲染内核

/// 把已解析的 `Document` 渲染成纵向 block 列表（无内层 ScrollView，滚动由调用方负责）。
/// 镜像 macOS `MarkdownBlocks`。
struct MMarkdownBlocks: View {
    let document: Markdown.Document
    var isStreaming: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(document.blockChildren.enumerated()), id: \.offset) { _, block in
                MMDBlockView(block: block, isStreaming: isStreaming)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MMDBlockView: View {
    let block: Markup
    var isStreaming: Bool = false
    @Environment(\.mMarkdownImageLoader) private var imageLoader

    var body: some View {
        switch block {
        case let h as Heading:         AnyView(headingView(h))
        case let p as Paragraph:
            if let imageLoader, MarkdownParagraphLayout.hasImages(p) {
                AnyView(paragraphWithImages(p, loader: imageLoader))
            } else {
                AnyView(MMDInlineView(node: p))
            }
        case let cb as CodeBlock:      AnyView(MChatCodeBlock(code: cb.code, language: cb.language, isStreaming: isStreaming))
        case let ul as UnorderedList:  AnyView(listView(items: Array(ul.listItems), ordered: false))
        case let ol as OrderedList:    AnyView(listView(items: Array(ol.listItems), ordered: true))
        case let bq as BlockQuote:     AnyView(blockQuoteView(bq))
        case let tbl as MarkdownTable: AnyView(tableView(tbl))
        case is ThematicBreak:         AnyView(Rectangle().fill(M.divider).frame(height: 1).padding(.vertical, 4))
        default:                       AnyView(EmptyView())
        }
    }

    private func paragraphWithImages(_ p: Paragraph, loader: MMarkdownImageLoader) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownParagraphLayout.segments(p).enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .text(let nodes):
                    MMDInlineView(nodes: nodes)
                case .images(let images) where images.count == 1:
                    MMDImageView(source: images[0].image.source ?? "", alt: images[0].image.plainText,
                                 loader: loader, link: images[0].destination)
                case .images(let images):
                    FlowLayout(spacing: 8) {
                        ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                            MMDImageView(source: image.image.source ?? "", alt: image.image.plainText,
                                         loader: loader, link: image.destination, maxWidthInRow: 240)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func headingView(_ h: Heading) -> some View {
        // iOS 继承的默认 body ≈17pt，而正文已显式钉到 15pt（见 MMDInlineView）——标题级别
        // 必须全部 ≥ 正文，否则 H3-H6 比正文还小、层级倒挂。故按 15pt 正文重新标定。
        let sizes: [CGFloat] = [24, 20, 18, 16, 15, 15]
        // 字号交给 MMDInlineView 自己设：它里面钉着正文字号，外面再套 `.font` 会被里面的盖掉（之前标题和正文一样大）。
        MMDInlineView(node: h, font: .system(size: sizes[min(h.level - 1, 5)], weight: .semibold))
            .padding(.top, h.level <= 2 ? 6 : 2)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private func listView(items: [ListItem], ordered: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(ordered ? "\(idx + 1)." : "•").foregroundStyle(M.text3)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(item.blockChildren.enumerated()), id: \.offset) { _, child in
                            MMDBlockView(block: child, isStreaming: isStreaming)
                        }
                    }
                }
            }
        }
        .padding(.leading, 2)
    }

    @ViewBuilder
    private func blockQuoteView(_ bq: BlockQuote) -> some View {
        HStack(spacing: 0) {
            Rectangle().fill(M.border).frame(width: 3)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(bq.blockChildren.enumerated()), id: \.offset) { _, c in
                    MMDBlockView(block: c, isStreaming: isStreaming)
                }
            }
            .padding(.leading, 10)
            .foregroundStyle(M.text3)
        }
    }

    @ViewBuilder
    private func tableView(_ tbl: MarkdownTable) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                ForEach(Array(tbl.head.cells.enumerated()), id: \.offset) { _, cell in
                    MMDInlineView(node: cell).frame(maxWidth: .infinity, alignment: .leading).bold()
                }
            }
            .padding(.vertical, 4).padding(.horizontal, 6)
            // 表头只加粗，不再垫底色：与首行之间已有 hairline。

            ForEach(Array(tbl.body.rows.enumerated()), id: \.offset) { _, row in
                HStack {
                    ForEach(Array(row.cells.enumerated()), id: \.offset) { _, cell in
                        MMDInlineView(node: cell).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.vertical, 4).padding(.horizontal, 6)
                .overlay(Rectangle().fill(M.divider).frame(height: 0.5), alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: MRadius.xs).stroke(M.border, lineWidth: 0.5))
    }
}

/// inline 子节点 → AttributedString → Text。镜像 macOS `MDInlineView`。
private struct MMDInlineView: View {
    /// 要画的 inline 节点：一整个块的子节点，或段落按图片切开后的一段（`MarkdownParagraphLayout`）。
    let nodes: [Markup]
    /// 切开的那段两头的空白（图片前后的空格、换行）去掉。
    private let trimsEnds: Bool
    private let font: Font

    init(node: Markup, font: Font = M.sans(15)) {
        nodes = Array(node.children)
        trimsEnds = false
        self.font = font
    }

    init(nodes: [Markup]) {
        self.nodes = nodes
        trimsEnds = true
        font = M.sans(15)
    }

    var body: some View {
        Text(trimsEnds ? MarkdownParagraphLayout.trimmed(attributed(nodes)) : attributed(nodes))
            // 显式钉正文字号：不能依赖继承的默认 body（iOS ≈17pt / macOS ≈13pt 跨平台不一致，
            // 会撑大正文并打乱标题层级）。15pt 与用户气泡一致。
            .font(font)
            .foregroundStyle(M.text)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }


    private func attributed(_ node: Markup) -> AttributedString {
        attributed(Array(node.children))
    }

    private func attributed(_ children: [Markup]) -> AttributedString {
        var result = AttributedString()
        for child in children {
            switch child {
            case let t as MarkdownText:
                result.append(AttributedString(t.string))
            case let s as Strong:
                var a = attributed(s); a.inlinePresentationIntent = .stronglyEmphasized; result.append(a)
            case let e as Emphasis:
                var a = attributed(e); a.inlinePresentationIntent = .emphasized; result.append(a)
            case let c as InlineCode:
                var a = AttributedString(c.code)
                // 钉定字号（不用 .body，跨平台默认不一致），底色用 panelHi 而非 inputBg——
                // 浅色下 inputBg(#FFFFFF) 与气泡 panel(#FFFFFF) 同色，内联 code「胶囊」看不出；
                // panelHi(浅 #EEEEEA / 暗 #1C1C20) 两档都与气泡底有对比。
                a.font = .system(size: 15, design: .monospaced)
                a.backgroundColor = M.panelHi
                a.foregroundColor = M.text
                result.append(a)
            case let link as MarkdownLink:
                var a = attributed(link)
                if let dest = link.destination, let url = URL(string: dest) {
                    a.link = url; a.foregroundColor = M.accent
                }
                result.append(a)
            case let img as MarkdownImage:
                var a = AttributedString("[image: \(img.source ?? "")]")
                a.foregroundColor = M.text3
                result.append(a)
            case is LineBreak: result.append(AttributedString("\n"))
            case is SoftBreak: result.append(AttributedString(" "))
            default:           result.append(attributed(child))
            }
        }
        return result
    }
}

// MARK: - 聊天代码块

/// 顶栏（语言名 + 复制）+ 纯等宽正文（自动换行）。镜像 macOS `ChatCodeBlock` 的结构，
/// 但不跑高亮（移动端无 CodeHighlighter），随主题取色而非强制深色。
struct MChatCodeBlock: View {
    let code: String
    let language: String?
    var isStreaming: Bool = false

    @State private var copied = false

    private var trimmed: String { code.trimmingCharacters(in: .newlines) }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: MRadius.md, style: .continuous) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Text(trimmed)
                .font(M.mono(12))
                .foregroundStyle(M.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(shape.fill(M.inputBg))
        .clipShape(shape)
    }

    private var header: some View {
        HStack {
            Text(language?.isEmpty == false ? language! : "code")
                .font(M.mono(10.5)).foregroundStyle(M.text3)
            Spacer()
            Button {
                UIPasteboard.general.string = trimmed
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            } label: {
                HStack(spacing: 4) {
                    MIcon(name: copied ? "check" : "copy", size: 11, color: copied ? M.success : M.text3)
                    Text(copied ? "已拷贝" : "拷贝")
                        .font(M.sans(10.5)).foregroundStyle(copied ? M.success : M.text3)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(copied ? "已拷贝代码" : "拷贝代码")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .overlay(alignment: .bottom) { Rectangle().fill(M.divider).frame(height: 1) }
    }
}

private typealias MarkdownText = Markdown.Text
private typealias MarkdownTable = Markdown.Table
private typealias MarkdownLink = Markdown.Link
private typealias MarkdownImage = Markdown.Image
