import UDesignKit
// uTerm/Views/Markdown/MarkdownBlocks.swift
import SwiftUI
import AppKit
import Markdown

/// Markdown 渲染内核：把已解析的 Document 渲染成纵向 block 列表（无内层 ScrollView，
/// 滚动由调用方负责）。颜色/字号全部来自 `MarkdownStyle`。
struct MarkdownBlocks: View {
    let document: Markdown.Document
    let style: MarkdownStyle
    var imageLoader: MarkdownImageLoader?
    var isStreaming: Bool = false
    /// 一次最多挂多少个顶层块（`MarkdownBlockWindow`）。默认不裁；
    /// 文件预览把它设成一段的大小，剩下的由 `moreBlocks` 的按钮放开。
    /// **这不是懒栈**：外层仍是 `VStack`（`1a0bd63d` 的窗口缩放卡死修复），
    /// 只是不把 5 万块一次全建出来。
    var maxBlocks: Int = .max
    /// 还有块没挂时，渲染这个「继续渲染」的尾巴。nil 表示调用方不提供
    /// （聊天皮肤不分段）。
    var moreBlocks: ((Int) -> AnyView)?

    var body: some View {
        let all = Array(document.blockChildren)
        let shown = maxBlocks > 0 && maxBlocks < all.count ? maxBlocks : all.count
        VStack(alignment: .leading, spacing: style.blockSpacing) {
            ForEach(Array(all.prefix(shown).enumerated()), id: \.offset) { _, block in
                MDBlockView(block: block, style: style,
                            imageLoader: imageLoader,
                            isStreaming: isStreaming)
            }
            if shown < all.count, let moreBlocks {
                moreBlocks(all.count - shown)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MDBlockView: View {
    let block: Markup
    let style: MarkdownStyle
    var imageLoader: MarkdownImageLoader?
    var isStreaming: Bool = false

    var body: some View {
        switch block {
        case let h as Heading:        AnyView(headingView(h))
        case let p as Paragraph:      AnyView(paragraphView(p))
        case let cb as CodeBlock:     AnyView(codeBlockView(cb))
        case let ul as UnorderedList: AnyView(listView(items: Array(ul.listItems), ordered: false))
        case let ol as OrderedList:   AnyView(listView(items: Array(ol.listItems), ordered: true))
        case let bq as BlockQuote:    AnyView(blockQuoteView(bq))
        case let tbl as MarkdownTable: AnyView(tableView(tbl))
        case is ThematicBreak:        AnyView(Rectangle().fill(style.border).frame(height: 1).padding(.vertical, 4))
        default:                      AnyView(EmptyView())
        }
    }

    @ViewBuilder
    private func headingView(_ h: Heading) -> some View {
        let sizes: [CGFloat] = [22, 18, 16, 14, 13, 12]
        MDInlineView(node: h, style: style)
            .font(.system(size: sizes[min(h.level - 1, 5)], weight: .semibold))
            .foregroundStyle(style.textPrimary)
            .padding(.top, h.level <= 2 ? 8 : 4)
            .accessibilityAddTraits(.isHeader)
    }

    /// 文档预览（有读图的人）：段落在图片处切开，规则两端共用（`MarkdownParagraphLayout`）——前后的文字照原顺序留着，
    /// 挨着的几张图排一行，包着链接的图点了打开链接。聊天（没有读图的人）照旧：只有整段一张图时画图片卡。
    @ViewBuilder
    private func paragraphView(_ p: Paragraph) -> some View {
        if imageLoader != nil, MarkdownParagraphLayout.hasImages(p) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(MarkdownParagraphLayout.segments(p).enumerated()), id: \.offset) { _, segment in
                    switch segment {
                    case .text(let nodes):
                        MDInlineView(nodes: nodes, style: style)
                    case .images(let images) where images.count == 1:
                        MDImageBlockView(image: images[0].image, style: style, imageLoader: imageLoader,
                                         link: images[0].destination)
                    case .images(let images):
                        FlowLayout(spacing: 8) {
                            ForEach(Array(images.enumerated()), id: \.offset) { _, item in
                                MDImageBlockView(image: item.image, style: style, imageLoader: imageLoader,
                                                 link: item.destination, maxWidthInRow: 320)
                            }
                        }
                    }
                }
            }
        } else if let image = imageOnly(in: p) {
            MDImageBlockView(image: image, style: style, imageLoader: imageLoader)
        } else {
            MDInlineView(node: p, style: style)
        }
    }

    @ViewBuilder
    private func codeBlockView(_ cb: CodeBlock) -> some View {
        if style.usesChatCodeBlock {
            ChatCodeBlock(code: cb.code, language: cb.language,
                          isStreaming: isStreaming, style: style)
        } else {
            Text(cb.code.trimmingCharacters(in: .newlines))
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(style.textSecondary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(style.codeBlockBackground)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }

    @ViewBuilder
    private func listView(items: [ListItem], ordered: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(ordered ? "\(idx + 1)." : "•")
                        .foregroundStyle(style.textMuted)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(item.blockChildren.enumerated()), id: \.offset) { _, child in
                            MDBlockView(block: child, style: style,
                                        imageLoader: imageLoader,
                                        isStreaming: isStreaming)
                        }
                    }
                }
            }
        }
        .padding(.leading, 4)
    }

    @ViewBuilder
    private func blockQuoteView(_ bq: BlockQuote) -> some View {
        HStack(spacing: 0) {
            Rectangle().fill(style.border).frame(width: 3)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(bq.blockChildren.enumerated()), id: \.offset) { _, c in
                    MDBlockView(block: c, style: style,
                                imageLoader: imageLoader,
                                isStreaming: isStreaming)
                }
            }
            .padding(.leading, 10)
            .foregroundStyle(style.textMuted)
        }
    }

    @ViewBuilder
    private func tableView(_ tbl: MarkdownTable) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                ForEach(Array(tbl.head.cells.enumerated()), id: \.offset) { _, cell in
                    MDInlineView(node: cell, style: style).frame(maxWidth: .infinity, alignment: .leading).bold()
                }
            }
            .padding(.vertical, 4).padding(.horizontal, 6)
            .background(style.bgRaised)

            ForEach(Array(tbl.body.rows.enumerated()), id: \.offset) { _, row in
                HStack {
                    ForEach(Array(row.cells.enumerated()), id: \.offset) { _, cell in
                        MDInlineView(node: cell, style: style).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.vertical, 4).padding(.horizontal, 6)
                .overlay(Rectangle().fill(style.border).frame(height: 0.5), alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 5).stroke(style.border, lineWidth: 0.5))
    }

    private func imageOnly(in node: Markup) -> MarkdownImage? {
        let children = Array(node.children)
        guard children.count == 1 else { return nil }
        if let image = children[0] as? MarkdownImage {
            return image
        }
        if children[0] is MarkdownLink {
            return imageOnly(in: children[0])
        }
        return nil
    }
}

private struct MDImageBlockView: View {
    let image: MarkdownImage
    let style: MarkdownStyle
    var imageLoader: MarkdownImageLoader?
    /// 包着这张图的链接：点图打开（只认网址，见 `MDImageLink`）。
    var link: String? = nil
    /// 和别的图排在一行时限的宽度（行布局按理想尺寸排）；nil = 单独一张，铺满可用宽度为止。
    var maxWidthInRow: CGFloat? = nil

    @State private var phase: Phase = .idle

    var body: some View {
        // Alt text is preserved for accessibility instead of rendered as a
        // visible gray caption (see MarkdownImageCaptionTests).
        content
            .accessibilityLabel(accessibilityLabel)
            .frame(maxWidth: maxWidthInRow == nil ? .infinity : nil, alignment: .leading)
            .modifier(MDImageLink(link: link))
            .task(id: source) {
                await load()
            }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .idle, .loading:
            if maxWidthInRow == nil {
                loadingView
            } else {
                ProgressView().controlSize(.small).frame(width: 44, height: 44)
            }
        case .loaded(let image):
            MDLoadedImageView(image: image, style: style, maxWidthInRow: maxWidthInRow)
        case .failed(let message):
            if maxWidthInRow == nil {
                failureView(message)
            } else {
                // 一行里的小图（多半是徽章）读不到：只留图标和替代文字，原因在悬停提示里。
                Label(accessibilityLabel, systemImage: "photo")
                    .font(UD.caption)
                    .foregroundStyle(style.textMuted)
                    .help(message)
            }
        }
    }

    private var loadingView: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(style.bgRaised)
            .frame(maxWidth: .infinity, minHeight: 120)
            .overlay {
                VStack(spacing: 8) {
                    UDIndeterminateBar()
                        .frame(width: 120)
                    Text("正在加载图片…")
                        .font(UD.caption)
                        .foregroundStyle(style.textMuted)
                }
            }
    }

    private func failureView(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(style.textMuted)
            VStack(alignment: .leading, spacing: 4) {
                Text(message)
                    .font(UD.caption)
                    .foregroundStyle(style.textSecondary)
                Text(source)
                    .font(UD.mono(10.5))
                    .foregroundStyle(style.textMuted)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(style.bgRaised)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(style.border, lineWidth: 0.5))
    }

    private var source: String {
        image.source?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var altText: String {
        plainText(in: image)
    }

    /// 无障碍标签：优先用图片的 alt 文本，缺失时回落到图片地址。
    private var accessibilityLabel: String {
        altText.isEmpty ? source : altText
    }

    @MainActor
    private func load() async {
        guard !source.isEmpty else {
            phase = .failed(String(localized: "图片地址为空"))
            return
        }
        guard let imageLoader else {
            phase = .failed(String(localized: "图片预览不可用"))
            return
        }

        phase = .loading
        do {
            let data = try await imageLoader(source)
            guard let loaded = await MarkdownImageDecoder.decode(data) else {
                phase = .failed(String(localized: "无法解码图片"))
                return
            }
            phase = .loaded(loaded)
        } catch {
            phase = .failed(String(localized: "图片加载失败：\(FriendlyError.describe(error))"))
        }
    }

    private enum Phase {
        case idle
        case loading
        case loaded(NSImage)
        case failed(String)
    }
}

struct MarkdownImageLayout {
    nonisolated static let maxPreviewHeight: CGFloat = 520

    nonisolated static func displaySize(intrinsic: CGSize,
                                        availableWidth: CGFloat,
                                        maxHeight: CGFloat = maxPreviewHeight) -> CGSize {
        guard intrinsic.width.isFinite,
              intrinsic.height.isFinite,
              intrinsic.width > 0,
              intrinsic.height > 0
        else {
            return .zero
        }

        let widthLimit = availableWidth.isFinite && availableWidth > 0
            ? availableWidth
            : intrinsic.width
        let heightLimit = maxHeight.isFinite && maxHeight > 0
            ? maxHeight
            : intrinsic.height
        let scale = min(1, widthLimit / intrinsic.width, heightLimit / intrinsic.height)

        return CGSize(
            width: (intrinsic.width * scale).rounded(.down),
            height: (intrinsic.height * scale).rounded(.down))
    }

    nonisolated static func frameLimit(intrinsic: CGSize,
                                       maxHeight: CGFloat = maxPreviewHeight) -> CGSize {
        guard intrinsic.width.isFinite,
              intrinsic.height.isFinite,
              intrinsic.width > 0,
              intrinsic.height > 0
        else {
            return .zero
        }

        return CGSize(width: intrinsic.width,
                      height: min(intrinsic.height, maxHeight))
    }
}

private struct MDLoadedImageView: View {
    let image: NSImage
    let style: MarkdownStyle
    var maxWidthInRow: CGFloat? = nil

    var body: some View {
        let frameLimit = MarkdownImageLayout.frameLimit(intrinsic: image.size)

        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .modifier(MDImageSizing(intrinsic: image.size, frameLimit: frameLimit, maxWidthInRow: maxWidthInRow))
            .background(style.bgRaised)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(style.border, lineWidth: 0.5))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 单独一张：不放大，宽高不超过 `frameLimit`，宽度由外面给。排在一行里：外面不给宽度，按比例算出确切的宽高，
/// 否则缩窄后的图还占着原来的高度、上下留白。
private struct MDImageSizing: ViewModifier {
    let intrinsic: CGSize
    let frameLimit: CGSize
    let maxWidthInRow: CGFloat?

    func body(content: Content) -> some View {
        if let cap = maxWidthInRow {
            let size = MarkdownImageLayout.displaySize(intrinsic: intrinsic, availableWidth: cap)
            content.frame(width: size.width, height: size.height)
        } else {
            content.frame(maxWidth: frameLimit.width, maxHeight: frameLimit.height, alignment: .leading)
        }
    }
}

/// 图外面包着网址链接：整张图可点，点了交给系统打开（同正文里的链接）。只认网址（`TerminalLink`）——
/// 文档是主机上的，里面的链接谁都能写。
private struct MDImageLink: ViewModifier {
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
                .pointerStyle(.link)
                .help(url.absoluteString)
                .accessibilityAddTraits(.isLink)
        } else {
            content
        }
    }
}

/// inline 子节点 → AttributedString → Text。
private struct MDInlineView: View {
    /// 一整个块的子节点，或段落按图片切开后的一段（`MarkdownParagraphLayout`，两头空白去掉）。
    let nodes: [Markup]
    let style: MarkdownStyle
    private let trimsEnds: Bool

    init(node: Markup, style: MarkdownStyle) {
        nodes = Array(node.children)
        self.style = style
        trimsEnds = false
    }

    init(nodes: [Markup], style: MarkdownStyle) {
        self.nodes = nodes
        self.style = style
        trimsEnds = true
    }

    var body: some View {
        Text(trimsEnds ? MarkdownParagraphLayout.trimmed(attributed(nodes)) : attributed(nodes))
            .foregroundStyle(style.bodyColor)
            .lineSpacing(style.lineSpacing)
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
                a.font = .system(.body, design: .monospaced)
                a.backgroundColor = style.inlineCodeBackground
                a.foregroundColor = style.textPrimary
                result.append(a)
            case let link as MarkdownLink:
                var a = attributed(link)
                if let dest = link.destination, let url = URL(string: dest) {
                    a.link = url; a.foregroundColor = style.accent
                }
                result.append(a)
            case let img as MarkdownImage:
                var a = AttributedString("[image: \(img.source ?? "")]")
                a.foregroundColor = style.textMuted
                result.append(a)
            case is LineBreak:  result.append(AttributedString("\n"))
            case is SoftBreak:  result.append(AttributedString(" "))
            default:            result.append(attributed(child))
            }
        }
        return result
    }
}

private func plainText(in node: Markup) -> String {
    var result = ""
    for child in node.children {
        if let text = child as? MarkdownText {
            result += text.string
        } else {
            result += plainText(in: child)
        }
    }
    return result
}

private typealias MarkdownText = Markdown.Text
private typealias MarkdownTable = Markdown.Table
private typealias MarkdownLink = Markdown.Link
private typealias MarkdownImage = Markdown.Image
