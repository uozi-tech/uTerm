import XCTest
@testable import uTerm

final class RemotePathTests: XCTestCase {
    func testJoin() {
        XCTAssertEqual(RemotePath.join("/", "a"), "/a")
        XCTAssertEqual(RemotePath.join("/home/user", "a b.txt"), "/home/user/a b.txt")
    }

    func testParent() {
        XCTAssertEqual(RemotePath.parent(of: "/"), "/")
        XCTAssertEqual(RemotePath.parent(of: "/home"), "/")
        XCTAssertEqual(RemotePath.parent(of: "/home/user"), "/home")
        XCTAssertEqual(RemotePath.parent(of: "/home/user/"), "/home")
        XCTAssertEqual(RemotePath.parent(of: "//"), "/")
        XCTAssertEqual(RemotePath.parent(of: ""), "/")
    }

    func testNormalized() {
        XCTAssertEqual(RemotePath.normalized(""), "/")
        XCTAssertEqual(RemotePath.normalized("/"), "/")
        XCTAssertEqual(RemotePath.normalized("a/b/"), "/a/b")
        XCTAssertEqual(RemotePath.normalized("/a/b///"), "/a/b")
    }

    func testBreadcrumbs() {
        let root = RemotePath.breadcrumbs("/")
        XCTAssertEqual(root.map(\.name), ["/"])
        XCTAssertEqual(root.map(\.full), ["/"])

        let crumbs = RemotePath.breadcrumbs("/home/user/日志")
        XCTAssertEqual(crumbs.map(\.name), ["/", "home", "user", "日志"])
        XCTAssertEqual(crumbs.map(\.full), ["/", "/home", "/home/user", "/home/user/日志"])
    }

    func testShellQuote() {
        XCTAssertEqual(RemotePath.shellQuote("/home/root"), "'/home/root'")
        XCTAssertEqual(RemotePath.shellQuote("/a b/c"), "'/a b/c'")
        XCTAssertEqual(RemotePath.shellQuote("/it's"), "'/it'\\''s'")
        XCTAssertEqual(RemotePath.shellQuote("$(rm -rf ~)"), "'$(rm -rf ~)'")
    }

    /// 既有调用面保留为转发，语义必须一致。
    func testLegacyForwardersMatch() {
        XCTAssertEqual(RemoteFileSearch.shSingleQuote("a'b"), RemotePath.shellQuote("a'b"))
    }
}
