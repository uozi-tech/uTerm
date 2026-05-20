import XCTest
@testable import uTerm

final class PaneKindTests: XCTestCase {
    func testTagCodableRoundTrip() throws {
        for tag in [PaneKindTag.terminal, .files] {
            let data = try JSONEncoder().encode(tag)
            let decoded = try JSONDecoder().decode(PaneKindTag.self, from: data)
            XCTAssertEqual(decoded, tag)
        }
    }

    func testTagRawValues() {
        XCTAssertEqual(PaneKindTag.terminal.rawValue, "terminal")
        XCTAssertEqual(PaneKindTag.files.rawValue, "files")
    }
}
