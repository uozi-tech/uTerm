import XCTest
import UDesignKit
@testable import uTerm

/// 两端共用的条目展示文案（`RemoteEntry+Display`）。
@MainActor
final class RemoteEntryDisplayTests: XCTestCase {
    private func entry(_ name: String, _ mode: UInt32?, size: UInt64?) -> RemoteEntry {
        RemoteEntry(name: name, posixPermissions: mode, size: size, modifiedAt: nil)
    }

    func testKindFollowsNameAndType() {
        XCTAssertEqual(entry("src", 0o040755, size: 4096).kind, .folder)
        XCTAssertEqual(entry("link", 0o120777, size: 7).kind, .symlink)
        XCTAssertEqual(entry("a.py", 0o100644, size: 1).kind.label, "Python 脚本")
    }

    func testSizeTextUsesPlaceholderForDirectoryAndMissingSize() {
        XCTAssertEqual(entry("d", 0o040755, size: 4096).sizeText, UFormat.placeholder)
        XCTAssertEqual(entry("f", 0o100644, size: nil).sizeText, UFormat.placeholder)
        XCTAssertEqual(entry("f", 0o100644, size: 2048).sizeText, UFormat.bytes(2048))
    }

    func testSizeOrKindText() {
        XCTAssertEqual(entry("d", 0o040755, size: 4096).sizeOrKindText, "文件夹")
        XCTAssertEqual(entry("f", 0o100644, size: nil).sizeOrKindText, UFormat.placeholder)
        XCTAssertEqual(entry("f", 0o100644, size: 10).sizeOrKindText, UFormat.bytes(10))
    }

    func testPermissionTexts() {
        let setuid = entry("sudo", 0o104755, size: 1)
        XCTAssertEqual(setuid.octalText, "4755")
        XCTAssertEqual(setuid.symbolicText, "-rwxr-xr-x")
        let unknown = entry("x", nil, size: nil)
        XCTAssertEqual(unknown.octalText, "—")
        XCTAssertEqual(unknown.symbolicText, "----------")
    }

    func testFullPath() {
        XCTAssertEqual(entry("a", 0o100644, size: 1).fullPath(in: "/"), "/a")
        XCTAssertEqual(entry("a", 0o100644, size: 1).fullPath(in: "/srv"), "/srv/a")
    }
}
