import XCTest
@testable import uTerm

final class RemoteEntryTests: XCTestCase {
    func testFileEntry() {
        let e = RemoteEntry(name: "readme.txt", posixPermissions: 0o100644,
                            size: 1234, modifiedAt: Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(e.name, "readme.txt")
        XCTAssertFalse(e.isDirectory)
        XCTAssertEqual(e.size, 1234)
        XCTAssertEqual(e.modifiedAt, Date(timeIntervalSince1970: 1000))
    }

    func testDirectoryEntry() {
        let e = RemoteEntry(name: "etc", posixPermissions: 0o040755,
                            size: nil, modifiedAt: nil)
        XCTAssertTrue(e.isDirectory)
        XCTAssertNil(e.size)
        XCTAssertNil(e.modifiedAt)
    }

    func testMissingPermissionsIsNotDirectory() {
        let e = RemoteEntry(name: "x", posixPermissions: nil, size: 0, modifiedAt: nil)
        XCTAssertFalse(e.isDirectory)
    }

    func testEquatable() {
        let a = RemoteEntry(name: "a", posixPermissions: 0o040755, size: nil, modifiedAt: nil)
        let b = RemoteEntry(name: "a", posixPermissions: 0o040755, size: nil, modifiedAt: nil)
        XCTAssertEqual(a, b)
    }
}
