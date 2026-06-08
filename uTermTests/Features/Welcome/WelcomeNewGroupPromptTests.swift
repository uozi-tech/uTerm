import XCTest
@testable import uTerm

final class WelcomeNewGroupPromptTests: XCTestCase {
    func testNewGroupPromptAvoidsBlockingAppKitModal() throws {
        let source = try String(contentsOf: repoRoot.appendingPathComponent(
            "uTerm/Features/Welcome/Views/WelcomeView.swift"
        ), encoding: .utf8)

        XCTAssertFalse(source.contains("runModal()"))
        XCTAssertTrue(source.contains("NewGroupPromptSheet"))
    }

    func testNewGroupPromptDoesNotAutofocusInput() throws {
        let source = try String(contentsOf: repoRoot.appendingPathComponent(
            "uTerm/Features/Welcome/Views/WelcomeView.swift"
        ), encoding: .utf8)

        XCTAssertFalse(source.contains("autoFocus: true"))
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
