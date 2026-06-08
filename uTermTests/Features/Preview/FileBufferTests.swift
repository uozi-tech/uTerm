import XCTest
@testable import uTerm

@MainActor
final class FileBufferTests: XCTestCase {

    func test_init_defaultsToLoadingNotDirty() {
        let buf = FileBuffer(remotePath: "/etc/nginx.conf", kind: .code(language: "nginx"))
        XCTAssertEqual(buf.state, .loading)
        XCTAssertFalse(buf.isDirty)
        XCTAssertEqual(buf.text, "")
        XCTAssertNil(buf.mtimeWhenLoaded)
    }

    func test_displayName_isBasename() {
        XCTAssertEqual(FileBuffer(remotePath: "/etc/nginx/nginx.conf", kind: .code(language: "nginx")).displayName, "nginx.conf")
        XCTAssertEqual(FileBuffer(remotePath: "README.md", kind: .markdown).displayName, "README.md")
        XCTAssertEqual(FileBuffer(remotePath: "/", kind: .plainText).displayName, "/")
    }

    func test_fileKind_codeLanguageRoundtrip() {
        let kind = FileKind.code(language: "swift")
        if case .code(let lang) = kind { XCTAssertEqual(lang, "swift") } else { XCTFail() }
    }

    func test_isDirtyMutates() {
        let buf = FileBuffer(remotePath: "x", kind: .plainText)
        XCTAssertFalse(buf.isDirty)
        buf.isDirty = true
        XCTAssertTrue(buf.isDirty)
    }

    func test_dataVersion_bumpsOnEveryImageDataAssignment() {
        let buf = FileBuffer(remotePath: "/img.png", kind: .image)
        XCTAssertEqual(buf.dataVersion, 0)

        buf.imageData = Data([0x1, 0x2, 0x3])
        XCTAssertEqual(buf.dataVersion, 1)

        // 字节数相同但内容不同的「重载」——版本号仍必须递增，否则解码键不变、旧图残留。
        buf.imageData = Data([0x4, 0x5, 0x6])
        XCTAssertEqual(buf.dataVersion, 2)

        // 清空也算重新赋值。
        buf.imageData = nil
        XCTAssertEqual(buf.dataVersion, 3)
    }
}
