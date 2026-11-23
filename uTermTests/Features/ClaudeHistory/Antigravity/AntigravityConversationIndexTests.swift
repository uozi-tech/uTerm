import XCTest
@testable import uTerm

/// 摘要库里几列的解法、`annotations/` 的标题。内容全是编的。
final class AntigravityConversationIndexTests: XCTestCase {
    func testWorkspaceURIs() {
        typealias I = AntigravityConversationInfo
        XCTAssertEqual(I.workspace(fromURIsJSON: #"["file:///home/user/projects/demo"]"#), "/home/user/projects/demo")
        XCTAssertEqual(I.workspace(fromURIsJSON: #"["file:///home/user/a%20b/c%E4%B8%AD"]"#), "/home/user/a b/c中")
        XCTAssertEqual(I.workspace(fromURIsJSON: #"["file:///a/one/","file:///a/two"]"#), "/a/one", "取第一个，去掉末尾的 /")
        XCTAssertEqual(I.workspace(fromURIsJSON: #"["vscode-remote://ssh/x","file:///a/two"]"#), "/a/two")
        XCTAssertNil(I.workspace(fromURIsJSON: ""))
        XCTAssertNil(I.workspace(fromURIsJSON: "[]"))
        XCTAssertNil(I.workspace(fromURIsJSON: "not json"))
        XCTAssertNil(I.path(fromFileURI: "file://otherhost/a"))
    }

    func testLastModifiedText() {
        let expected = try! Date("2026-11-20T02:00:00.5Z", strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        XCTAssertEqual(AntigravityConversationInfo.date(fromSQLiteText: "2026-11-20 10:00:00.500000+08:00")?.timeIntervalSince1970 ?? 0,
                       expected.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertNotNil(AntigravityConversationInfo.date(fromSQLiteText: "2026-11-20 10:00:00+08:00"))
        XCTAssertNil(AntigravityConversationInfo.date(fromSQLiteText: "yesterday"))
    }

    func testAnnotationTitle() {
        func title(_ text: String) -> String? { AntigravityAnnotation.title(in: Data(text.utf8)) }
        XCTAssertEqual(title(#"title:"修一下构建" last_user_view_time:{seconds:1 nanos:2}"#), "修一下构建")
        XCTAssertEqual(title(#"title: "say \"hi\" \\ there""#), #"say "hi" \ there"#)
        // 八进制写的是 UTF-8 字节。
        XCTAssertEqual(title(#"title:"\344\270\255\346\226\207 ok""#), "中文 ok")
        XCTAssertEqual(title(#"title:"two\nlines""#), "two lines")
        XCTAssertEqual(title(#"subtitle:"no" title:"yes""#), "yes")
        XCTAssertEqual(title(#"other:"title:\"fake\"" title:"real""#), "real", "字符串里的 title 不算")
        XCTAssertNil(title(#"last_user_view_time:{seconds:1}"#))
        XCTAssertNil(title(#"title:"""#))
        XCTAssertNil(title(#"title:"unterminated"#))
    }
}
