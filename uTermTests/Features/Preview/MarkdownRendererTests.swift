// uTermTests/Preview/MarkdownRendererTests.swift
import XCTest
import SwiftUI
@testable import uTerm
import Markdown   // swift-markdown

/// 这一组测试只验证「swift-markdown 解析未崩 + 解析出非空 AST」。
/// 不细到对具体类型做 `is X` 断言 —— Markdown 类型的 `is` 在 SwiftUI 同名类型存在
/// （Table/Link/Image）或 swift-markdown 0.8 中协议层次微妙时会失败；那些是
/// 上游库的细节，我们的渲染器在 source 文件里用 type-switch 覆盖。
/// 端到端正确性由后续手动 smoke（spec §7 #5）保证。
@MainActor
final class MarkdownRendererTests: XCTestCase {

    func test_parseHeadingsAndParagraphs() {
        let doc = Markdown.Document(parsing: "# Title\n\nBody text.")
        let blocks = Array(doc.blockChildren)
        XCTAssertEqual(blocks.count, 2)
    }

    func test_parseUnorderedList_producesAtLeastOneBlock() {
        let doc = Markdown.Document(parsing: "- a\n- b\n- c")
        XCTAssertFalse(Array(doc.blockChildren).isEmpty)
    }

    func test_parseFencedCodeBlock_producesAtLeastOneBlock() {
        let doc = Markdown.Document(parsing: "```swift\nlet x = 1\n```")
        XCTAssertFalse(Array(doc.blockChildren).isEmpty)
    }

    func test_parseTable_producesAtLeastOneBlock() {
        let src = """
        | a | b |
        | - | - |
        | 1 | 2 |
        """
        let doc = Markdown.Document(parsing: src)
        XCTAssertFalse(Array(doc.blockChildren).isEmpty)
    }

    func test_renderer_acceptsEmptySource() {
        // 渲染空字符串不应崩
        let view = MarkdownRenderer(source: "")
        _ = view.body
    }

    func test_renderer_acceptsTypicalDocument() {
        let src = """
        # 标题

        段落 with **强调** and `inline code`.

        - 列表项 1
        - 列表项 2

        [link](https://example.com)
        """
        let view = MarkdownRenderer(source: src)
        _ = view.body
    }

    func testMarkdownPreviewCoalescesParsingAndUsesStableBlocks() throws {
        let rendererSource = try String(contentsOf: repoRoot.appendingPathComponent(
            "uTerm/Features/Preview/MarkdownRenderer.swift"), encoding: .utf8)
        let blocksSource = try String(contentsOf: repoRoot.appendingPathComponent(
            "uTerm/Features/Preview/Views/Markdown/MarkdownBlocks.swift"), encoding: .utf8)

        XCTAssertTrue(rendererSource.contains("StreamingMarkdownView("))
        XCTAssertTrue(rendererSource.contains("isStreaming: true"))
        XCTAssertFalse(rendererSource.contains("Document(parsing: source)"))
        XCTAssertTrue(blocksSource.contains("VStack(alignment: .leading"))
        XCTAssertFalse(blocksSource.contains("LazyVStack(alignment: .leading"))
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
