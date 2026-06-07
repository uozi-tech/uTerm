import XCTest
@testable import uTerm

final class MarkdownImageCaptionTests: XCTestCase {
    func testStandaloneMarkdownImageDoesNotRenderAltTextCaption() throws {
        let source = try String(contentsOf: repoRoot.appendingPathComponent(
            "uTerm/Features/Preview/Views/Markdown/MarkdownBlocks.swift"),
                                encoding: .utf8)

        XCTAssertFalse(
            source.contains("Text(altText)"),
            "Standalone markdown images should not render their alt text as a visible caption.")
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
