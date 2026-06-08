import XCTest
@testable import uTerm

@MainActor
final class SFTPFileTableColumnLayoutTests: XCTestCase {
    func testWideTableCapsNameColumnSoMetadataDoesNotDriftToFarEdge() {
        let widths = SFTPFileTableColumnWidths(containerWidth: 1_640)
        let name = widths.name
        let owner = widths.owner
        let permissions = widths.permissions
        let modified = widths.modified
        let size = widths.size
        let occupiedContentWidth = widths.occupiedContentWidth
        let availableContentWidth = 1_640 - SFTPFileTableColumnWidths.horizontalPadding * 2

        XCTAssertEqual(name, 720)
        XCTAssertEqual(owner, 112)
        XCTAssertEqual(permissions, 72)
        XCTAssertEqual(modified, 156)
        XCTAssertEqual(size, 84)
        XCTAssertLessThan(occupiedContentWidth, availableContentWidth)
    }

    func testRegularTableKeepsModifiedAndSizeColumnsReadable() {
        let widths = SFTPFileTableColumnWidths(containerWidth: 1_000)
        let owner = widths.owner
        let permissions = widths.permissions
        let modified = widths.modified
        let size = widths.size
        let name = widths.name

        XCTAssertEqual(owner, 112)
        XCTAssertEqual(permissions, 72)
        XCTAssertEqual(modified, 156)
        XCTAssertEqual(size, 84)
        XCTAssertGreaterThanOrEqual(name, 240)
    }

    func testNarrowTableCompressesMetadataBeforeDroppingBelowMinimumNameWidth() {
        let widths = SFTPFileTableColumnWidths(containerWidth: 720)
        let name = widths.name
        let owner = widths.owner
        let modified = widths.modified
        let occupiedContentWidth = widths.occupiedContentWidth
        let availableContentWidth = 720 - SFTPFileTableColumnWidths.horizontalPadding * 2

        XCTAssertGreaterThanOrEqual(name, 240)
        XCTAssertLessThan(owner, 112)
        XCTAssertLessThan(modified, 156)
        XCTAssertLessThanOrEqual(occupiedContentWidth, availableContentWidth)
    }
}
