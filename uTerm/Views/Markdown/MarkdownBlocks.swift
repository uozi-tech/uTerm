// uTerm/Views/Markdown/MarkdownBlocks.swift
import SwiftUI
import Markdown

/// Markdown 渲染内核：把已解析的 Document 渲染成纵向 block 列表（无内层 ScrollView，
/// 滚动由调用方负责）。颜色/字号全部来自 `MarkdownStyle`。
struct MarkdownBlocks: View {
    let document: Document
    let style: MarkdownStyle
    var isStreaming: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: style.blockSpacing) {
            ForEach(Array(document.blockChildren.enumerated()), id: \.offset) { _, block in
                MDBlockView(block: block, style: style, isStreaming: isStreaming)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MDBlockView: View {
    let block: Markup
    let style: MarkdownStyle
    var isStreaming: Bool = false

    var body: some View {
        switch block {
        case let h as Heading:        AnyView(headingView(h))
        case let p as Paragraph:      AnyView(MDInlineView(node: p, style: style))
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
                            MDBlockView(block: child, style: style, isStreaming: isStreaming)
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
                    MDBlockView(block: c, style: style, isStreaming: isStreaming)
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
}

/// inline 子节点 → AttributedString → Text。
private struct MDInlineView: View {
    let node: Markup
    let style: MarkdownStyle
    var body: some View {
        Text(attributed(node))
            .foregroundStyle(style.bodyColor)
            .lineSpacing(style.lineSpacing)
    }

    private func attributed(_ node: Markup) -> AttributedString {
        var result = AttributedString()
        for child in node.children {
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

private typealias MarkdownText = Markdown.Text
private typealias MarkdownTable = Markdown.Table
private typealias MarkdownLink = Markdown.Link
private typealias MarkdownImage = Markdown.Image
