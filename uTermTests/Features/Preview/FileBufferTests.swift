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
}
