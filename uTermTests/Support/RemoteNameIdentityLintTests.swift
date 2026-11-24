import Foundation
import XCTest

/// 源码 lint：远端名字 / 路径的「是不是同一个文件」只能逐字节比（`RemoteNameKey`，`a.remoteKey == b.remoteKey`）。
///
/// ## 为什么
///
/// Swift 的 `String ==` 按标准等价比较，NFC 与 NFD 写法的 `café.txt` 是「同一个串」，可在 Linux 上是两个文件：
/// 选中第二个、改名 / 删除 / 打开的却是第一个。这条 lint 扫文件浏览、预览、外部打开几处的源码，拦住把
/// `remotePath` / `currentPath` / 条目的 `name` 直接拿 `==` / `!=` 和另一个变量比的写法（和字面量比，如
/// `currentPath != "/"`，不受归一化影响，放行；`key == .name` 这类枚举比较不算）。
final class RemoteNameIdentityLintTests: XCTestCase {

    private static let roots = [
        "uTerm/Features/Files", "uTerm/Features/Preview", "uTerm/Features/ExternalOpen", "uTerm/Features/SFTP",
        "uTermMobile/Screens/SFTP",
    ]

    func testRemotePathsAndNamesAreComparedByBytes() throws {
        let repo = DefaultsKeyLintTests.repoRoot
        var files: [URL] = []
        for root in Self.roots {
            let url = repo.appendingPathComponent(root)
            guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else { continue }
            for case let file as URL in walker where file.pathExtension == "swift" { files.append(file) }
        }
        XCTAssertGreaterThan(files.count, 20, "夹具失效：没扫到源码")
        let pattern = /(\bremotePath|\bcurrentPath|\w\.name)\s*(==|!=)\s*([^\s]+)|([^\s]+)\s*(==|!=)\s*[\w$.]*\w\.(remotePath|currentPath|name)\b|([^\s]+)\s*(==|!=)\s*\b(remotePath|currentPath)\b/
        var offenders: [String] = []
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                if code.hasPrefix("//") || line.contains("remoteKey") { continue }
                guard let match = line.firstMatch(of: pattern) else { continue }
                if let rhs = match.output.3, rhs.hasPrefix("\"") { continue }
                if let lhs = match.output.4, lhs.hasSuffix("\"") { continue }
                if let lhs = match.output.7, lhs.hasSuffix("\"") { continue }
                offenders.append("\(file.lastPathComponent):\(index + 1): \(code)")
            }
        }
        XCTAssertTrue(offenders.isEmpty, """
            远端路径 / 名字用 String 的 == / != 比较（\(offenders.count) 处），NFC / NFD 的同名文件会被当成一个：
            \(offenders.joined(separator: "\n"))
            改成 `a.remoteKey == b.remoteKey`（见 RemoteNameKey）。
            """)
    }
}
