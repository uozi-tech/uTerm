import XCTest
@testable import uTerm

final class PreviewBufferBodyWiringTests: XCTestCase {
    func testEveryPreviewBufferBodyCallWiresMarkdownImageLoader() throws {
        let files = [
            "uTerm/Features/Preview/Views/PreviewBodyRouter.swift",
            "uTerm/Features/Preview/Views/PreviewArea.swift",
            "uTerm/Features/Workspace/Views/PaneView.swift",
        ]

        for file in files {
            let source = try String(contentsOf: repoRoot.appendingPathComponent(file),
                                    encoding: .utf8)
            let calls = callArguments(named: "PreviewBufferBody", in: source)
            XCTAssertFalse(calls.isEmpty, "\(file) should contain a PreviewBufferBody call")

            for arguments in calls {
                XCTAssertTrue(
                    arguments.contains("onLoadMarkdownImage:"),
                    "\(file) has a PreviewBufferBody call without Markdown image loader wiring")
            }
        }
    }

    func testRecentFileRowsDoNotDeclareKeyboardFocusRing() throws {
        let source = try String(contentsOf: repoRoot.appendingPathComponent(
            "uTerm/Features/Preview/Views/EmptyBody.swift"
        ), encoding: .utf8)

        XCTAssertFalse(source.contains(".focusable("))
        XCTAssertFalse(source.contains(".focusEffectDisabled("))
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func callArguments(named name: String, in source: String) -> [String] {
        var results: [String] = []
        var searchStart = source.startIndex

        while searchStart < source.endIndex,
              let nameRange = source.range(of: name, range: searchStart..<source.endIndex),
              let openParen = source[nameRange.upperBound...].firstIndex(of: "(") {
            var index = source.index(after: openParen)
            var depth = 1
            var inString = false
            var escaped = false

            while index < source.endIndex {
                let character = source[index]
                defer { index = source.index(after: index) }

                if inString {
                    if escaped {
                        escaped = false
                    } else if character == "\\" {
                        escaped = true
                    } else if character == "\"" {
                        inString = false
                    }
                    continue
                }

                switch character {
                case "\"":
                    inString = true
                case "(":
                    depth += 1
                case ")":
                    depth -= 1
                    if depth == 0 {
                        results.append(String(source[source.index(after: openParen)..<index]))
                        searchStart = source.index(after: index)
                        break
                    }
                default:
                    break
                }
            }

            if depth != 0 {
                break
            }
        }

        return results
    }
}
