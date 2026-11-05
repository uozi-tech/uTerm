import XCTest

/// 系统菜单必须走 `MMenu` / `mContextMenu`：直接写 `Menu` / `.contextMenu` 会继承根视图的 tint，
/// 图标被染成强调色，和文字对不上（典型是「删除」红字配蓝图标）。
///
/// 渲染结果由系统菜单决定，单测里读不到颜色，所以这里守的是调用方式。
final class MMenuTintLintTests: XCTestCase {
    func testMobileMenusResetInheritedTint() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("uTermMobile")
        let pattern = try NSRegularExpression(pattern: #"(?<![A-Za-z])Menu\s*(\{|\()|\.contextMenu\b"#)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))

        var scanned = 0
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            scanned += 1
            guard url.lastPathComponent != "MMenu.swift" else { continue }
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() {
                let code = line.components(separatedBy: "//")[0]
                let range = NSRange(code.startIndex..., in: code)
                if pattern.firstMatch(in: code, range: range) != nil {
                    offenders.append("\(url.lastPathComponent):\(index + 1)")
                }
            }
        }

        XCTAssertGreaterThan(scanned, 50, "没扫到源码，路径可能不对：\(root.path)")
        XCTAssertEqual(offenders, [], "改用 MMenu / mContextMenu")
    }
}
