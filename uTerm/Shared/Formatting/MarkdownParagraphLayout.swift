import Foundation
import Markdown

/// 两端的 Markdown 预览共用（Mac `MarkdownBlocks`、iOS `MAgentMarkdown`）。
/// 文档预览里（有读图的人时）段落按图片切开：图片之间、图片前后的文字照原顺序留成文字，图片画成图。挨着的几张图（中间只有空白，
/// 比如一排徽章、两张并排的截图）放一行，排不下换行。没有图的段落不切，照旧一整段文字。
/// 外面包着链接、里面只有图的（GitHub 徽章的 `[![build](…)](链接)`）也算图，带着那个链接。
nonisolated enum MarkdownParagraphLayout {
    struct LinkedImage {
        let image: Markdown.Image
        /// 包着它的链接；没有就是 nil。
        let destination: String?
    }

    enum Segment {
        case text([Markup])
        case images([LinkedImage])
    }

    /// 段落里有没有要画成图的（图片，或只包着图片的链接）。
    static func hasImages(_ paragraph: Paragraph) -> Bool {
        paragraph.children.contains { !linkedImages(in: $0).isEmpty }
    }

    static func segments(_ paragraph: Paragraph) -> [Segment] {
        var segments: [Segment] = []
        var text: [Markup] = []
        var images: [LinkedImage] = []
        /// 两张图之间的空白：后面接着是图就丢掉，接着是文字就还给文字。
        var gap: [Markup] = []

        func flushText() {
            if text.contains(where: { !isBlank($0) }) { segments.append(.text(text)) }
            text = []
        }
        func flushImages() {
            if !images.isEmpty { segments.append(.images(images)) }
            images = []
        }

        for child in paragraph.children {
            let found = linkedImages(in: child)
            if !found.isEmpty {
                if images.isEmpty { flushText() }
                gap = []
                images += found
            } else if !images.isEmpty, isBlank(child) {
                gap.append(child)
            } else {
                flushImages()
                text += gap
                gap = []
                text.append(child)
            }
        }
        flushImages()
        flushText()
        return segments
    }

    /// 这个 inline 节点本身是图，或是只包着图（加空白）的链接：返回里面的图；别的返回空。
    private static func linkedImages(in node: Markup) -> [LinkedImage] {
        if let image = node as? Markdown.Image { return [LinkedImage(image: image, destination: nil)] }
        guard let link = node as? Markdown.Link else { return [] }
        var images: [LinkedImage] = []
        for child in link.children {
            if let image = child as? Markdown.Image {
                images.append(LinkedImage(image: image, destination: link.destination))
            } else if !isBlank(child) {
                return []
            }
        }
        return images
    }

    /// 切开的那段文字两头的空白（图片前后的空格、换行）去掉。
    static func trimmed(_ text: AttributedString) -> AttributedString {
        var text = text
        while let first = text.characters.first, first.isWhitespace {
            text.removeSubrange(text.startIndex..<text.index(afterCharacter: text.startIndex))
        }
        while let last = text.characters.last, last.isWhitespace {
            text.removeSubrange(text.index(beforeCharacter: text.endIndex)..<text.endIndex)
        }
        return text
    }

    private static func isBlank(_ node: Markup) -> Bool {
        switch node {
        case is SoftBreak, is LineBreak: return true
        case let text as Markdown.Text: return text.string.allSatisfy(\.isWhitespace)
        default: return false
        }
    }
}
