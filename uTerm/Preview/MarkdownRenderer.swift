// uTerm/Preview/MarkdownRenderer.swift
import SwiftUI
import Markdown

/// 把 Markdown 源码渲染为 SwiftUI 视图。
/// 支持：h1-h6、p、em、strong、code、pre、ul、ol、li、blockquote、table、hr、link。
/// 不支持：footnote、task list checkbox、math、inline HTML、image（占位）。
struct MarkdownRenderer: View {
    let source: String

    var body: some View {
        let document = Document(parsing: source)
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(document.blockChildren.enumerated()), id: \.offset) { _, block in
                    BlockView(block: block)
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// 单个 block-level 节点的渲染。AnyView 包是为了让 ForEach 的 closure 返回固定类型。
private struct BlockView: View {
    let block: Markup

    var body: some View {
        switch block {
        case let h as Heading:        AnyView(headingView(h))
        case let p as Paragraph:      AnyView(InlineView(node: p))
        case let cb as CodeBlock:     AnyView(codeBlockView(cb))
        case let ul as UnorderedList: AnyView(listView(items: Array(ul.listItems), ordered: false))
        case let ol as OrderedList:   AnyView(listView(items: Array(ol.listItems), ordered: true))
        case let bq as BlockQuote:    AnyView(blockQuoteView(bq))
        case let tbl as MarkdownTable:        AnyView(tableView(tbl))
        case is ThematicBreak:        AnyView(Rectangle().fill(AppTheme.Palette.border).frame(height: 1).padding(.vertical, 4))
        default:                      AnyView(EmptyView())
        }
    }

    @ViewBuilder
    private func headingView(_ h: Heading) -> some View {
        let size: CGFloat = [22, 18, 16, 14, 13, 12][min(h.level - 1, 5)]
        InlineView(node: h)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(AppTheme.Palette.textPrimary)
            .padding(.top, h.level <= 2 ? 8 : 4)
    }

    @ViewBuilder
    private func codeBlockView(_ cb: CodeBlock) -> some View {
        Text(cb.code.trimmingCharacters(in: .newlines))
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(AppTheme.Palette.textSecondary)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.Palette.bgRaised)
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    @ViewBuilder
    private func listView(items: [ListItem], ordered: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(ordered ? "\(idx + 1)." : "•")
                        .foregroundStyle(AppTheme.Palette.textMuted)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(item.blockChildren.enumerated()), id: \.offset) { _, child in
                            BlockView(block: child)
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
            Rectangle().fill(AppTheme.Palette.border).frame(width: 3)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(bq.blockChildren.enumerated()), id: \.offset) { _, c in
                    BlockView(block: c)
                }
            }
            .padding(.leading, 10)
            .foregroundStyle(AppTheme.Palette.textMuted)
        }
    }

    @ViewBuilder
    private func tableView(_ tbl: MarkdownTable) -> some View {
        let head = tbl.head
        let body = tbl.body
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                ForEach(Array(head.cells.enumerated()), id: \.offset) { _, cell in
                    InlineView(node: cell).frame(maxWidth: .infinity, alignment: .leading).bold()
                }
            }
            .padding(.vertical, 4).padding(.horizontal, 6)
            .background(AppTheme.Palette.bgRaised)

            ForEach(Array(body.rows.enumerated()), id: \.offset) { _, row in
                HStack {
                    ForEach(Array(row.cells.enumerated()), id: \.offset) { _, cell in
                        InlineView(node: cell).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.vertical, 4).padding(.horizontal, 6)
                .overlay(Rectangle().fill(AppTheme.Palette.border).frame(height: 0.5), alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 5).stroke(AppTheme.Palette.border, lineWidth: 0.5))
    }
}

/// 把 inline 子节点拼成 AttributedString → Text。
private struct InlineView: View {
    let node: Markup
    var body: some View {
        Text(attributed(node))
            .foregroundStyle(AppTheme.Palette.textSecondary)
    }

    private func attributed(_ node: Markup) -> AttributedString {
        var result = AttributedString()
        for child in node.children {
            switch child {
            case let t as MarkdownText:
                result.append(AttributedString(t.string))
            case let s as Strong:
                var a = attributed(s)
                a.inlinePresentationIntent = .stronglyEmphasized
                result.append(a)
            case let e as Emphasis:
                var a = attributed(e)
                a.inlinePresentationIntent = .emphasized
                result.append(a)
            case let c as InlineCode:
                var a = AttributedString(c.code)
                a.font = .system(.body, design: .monospaced)
                a.backgroundColor = AppTheme.Palette.bgRaised
                result.append(a)
            case let link as MarkdownLink:
                var a = attributed(link)
                if let dest = link.destination, let url = URL(string: dest) {
                    a.link = url
                    a.foregroundColor = AppTheme.Palette.accent
                }
                result.append(a)
            case let img as MarkdownImage:
                var a = AttributedString("[image: \(img.source ?? "")]")
                a.foregroundColor = AppTheme.Palette.textMuted
                result.append(a)
            case is LineBreak:
                result.append(AttributedString("\n"))
            case is SoftBreak:
                result.append(AttributedString(" "))
            default:
                // 兜底：递归把孩子的文本拼起来
                result.append(attributed(child))
            }
        }
        return result
    }
}

/// 命名冲突：Markdown 与 SwiftUI 都有 `Text`/`Table`/`Link`/`Image` —— 用 typealias 区分。
private typealias MarkdownText = Markdown.Text
private typealias MarkdownTable = Markdown.Table
private typealias MarkdownLink = Markdown.Link
private typealias MarkdownImage = Markdown.Image
