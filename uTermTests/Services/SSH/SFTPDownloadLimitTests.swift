import XCTest
@testable import uTerm
@testable import USSHKit

final class SFTPDownloadLimitTests: XCTestCase {
    func testClampedSizeRejectsHostileUInt64WithoutOverflowing() {
        XCTAssertEqual(SFTPSession.clampedSize(nil), 0)
        XCTAssertEqual(SFTPSession.clampedSize(42), 42)
        XCTAssertEqual(SFTPSession.clampedSize(UInt64.max), Int64.max)
    }
}
