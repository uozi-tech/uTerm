import XCTest

final class ChatCodeBlockAppearanceTests: XCTestCase {
    func testCodeBlockFollowsAppAppearanceAndPreservesPreformattedLines() throws {
        let source = try String(contentsOf: repoRoot.appendingPathComponent(
            "uTerm/Features/Preview/Views/Markdown/ChatCodeBlock.swift"),
                                encoding: .utf8)

        XCTAssertFalse(
            source.contains(".environment(\\.colorScheme, .dark)"),
            "Chat code blocks must not force dark foreground colors onto the adaptive light surface.")
        XCTAssertTrue(
            source.contains("ScrollView(.horizontal)"),
            "Preformatted diagnostic lines should scroll horizontally in a narrow assistant pane.")
        XCTAssertTrue(
            source.contains(".fixedSize(horizontal: true, vertical: false)"),
            "Preformatted diagnostic lines must not wrap their aligned status columns or emoji.")
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
