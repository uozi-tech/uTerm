import XCTest
import SwiftUI
@testable import uTerm

// BrowserFileKind 持有 SwiftUI Color，在 app 模块的 @MainActor 默认隔离下
// 其 from/label/tag 及 Equatable 一致性都被钉在主线程；测试类对齐到主 actor。
@MainActor
final class FileKindTests: XCTestCase {
    func testFolderKind() {
        XCTAssertEqual(BrowserFileKind.from(name: "Projects", isDirectory: true), .folder)
    }

    func testPythonKindLabelAndTag() {
        let k = BrowserFileKind.from(name: "update-pay.py", isDirectory: false)
        XCTAssertEqual(k.label, "Python 脚本")
        XCTAssertEqual(k.tag, "PY")
    }

    func testYamlAliases() {
        XCTAssertEqual(BrowserFileKind.from(name: "a.yml", isDirectory: false).tag, "YML")
        XCTAssertEqual(BrowserFileKind.from(name: "a.yaml", isDirectory: false).tag, "YML")
    }

    func testArchiveAndMarkdownAndPlain() {
        XCTAssertEqual(BrowserFileKind.from(name: "backup.tar.gz", isDirectory: false).label, "归档")
        XCTAssertEqual(BrowserFileKind.from(name: "README.md", isDirectory: false).label, "Markdown")
        XCTAssertEqual(BrowserFileKind.from(name: "TODO", isDirectory: false).label, "文件")
        XCTAssertNil(BrowserFileKind.from(name: "TODO", isDirectory: false).tag)
    }

    func testPermissionStringDirectory() {
        XCTAssertEqual(posixPermissionString(0o040755), "drwxr-xr-x")
    }

    func testPermissionStringFile() {
        XCTAssertEqual(posixPermissionString(0o100644), "-rw-r--r--")
    }

    func testPermissionStringPrivateDir() {
        XCTAssertEqual(posixPermissionString(0o040700), "drwx------")
    }

    func testPermissionStringNil() {
        XCTAssertEqual(posixPermissionString(nil), "----------")
    }

    // MARK: 八进制权限串

    func testOctalStringDirectory() {
        XCTAssertEqual(posixOctalString(0o040755), "755")
    }

    func testOctalStringFile() {
        XCTAssertEqual(posixOctalString(0o100644), "644")
    }

    func testOctalStringPrivateDir() {
        XCTAssertEqual(posixOctalString(0o040700), "700")
    }

    /// 含特殊位（setuid 4 / setgid 2 / sticky 1）时前缀一位八进制。
    func testOctalStringWithSpecialBits() {
        XCTAssertEqual(posixOctalString(0o104755), "4755")   // setuid 可执行
        XCTAssertEqual(posixOctalString(0o041777), "1777")   // sticky 目录（/tmp）
    }

    func testOctalStringNil() {
        XCTAssertEqual(posixOctalString(nil), "—")
    }
}

extension FileKindTests {
    func testRemoteEntryKeepsPermissionsAndOwner() {
        let e = RemoteEntry(name: "x", posixPermissions: 0o040755,
                            size: nil, modifiedAt: nil, uid: 0, gid: 0)
        XCTAssertEqual(e.permissions, 0o040755)
        XCTAssertEqual(e.uid, 0)
        XCTAssertEqual(e.gid, 0)
        XCTAssertTrue(e.isDirectory)
    }

    func testRemoteEntryOwnerDefaultsNil() {
        let e = RemoteEntry(name: "x", posixPermissions: 0o100644, size: 10, modifiedAt: nil)
        XCTAssertNil(e.uid)
        XCTAssertNil(e.gid)
    }
}
