import Foundation
import XCTest

/// 生产源码 lint：进程内 SSH 测试服务端 `USSHTestServer` 只给测试用。
///
/// ## 为什么
///
/// 它编在 `USSHStack.framework` 里（macOS 的测试 bundle 只能从那里拿到 SSH 栈，见 `Packages/USSHStack/Package.swift`），
/// 所以 App 里写一句 `import USSHTestServer` 也编得过——一个能接受任意密码的 SSH 服务端就这样进了产品逻辑。
/// 这条 lint 拦住所有非测试源码里对它的 import，以及 Xcode 工程里任何 target 直接声明它。
final class USSHTestServerLintTests: XCTestCase {

    /// 非测试的源码目录（App、辅助程序、扩展、本地包）。
    private static let productionRoots = [
        "uTerm", "uTermMobile", "uTermSSH", "uTermHolder", "uTermFiles", "uTermRemoteHost",
        "uTermShellAgent", "uTermLiveActivity", "uTermActivityShared", "uTermBackgroundLauncher", "Packages",
    ]

    func testNoProductionSourceImportsTheTestServer() throws {
        let files = try Self.swiftFiles()
        XCTAssertGreaterThan(files.count, 300, "夹具失效：没扫到生产源码")
        let rootPath = DefaultsKeyLintTests.repoRoot.path + "/"
        var offenders: [String] = []
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() where line.contains(/^\s*(@[\w()]+\s+)*import\s+(\w+\s+)?USSHTestServer\b/) {
                offenders.append("\(file.path.replacingOccurrences(of: rootPath, with: "")):\(index + 1)")
            }
        }
        XCTAssertTrue(offenders.isEmpty, """
            生产代码 import 了测试服务端 USSHTestServer（\(offenders.count) 处）：
            \(offenders.joined(separator: "\n"))
            它只给测试用（谁来都放行的 SSH 服务端），别在 App 里用。
            """)
    }

    /// Xcode 工程里没有任何 target 直接声明 `USSHTestServer` product（它只经 `USSHStack` 进 macOS 的 framework）。
    func testNoTargetDeclaresTheTestServerProduct() throws {
        let project = DefaultsKeyLintTests.repoRoot.appendingPathComponent("uTerm.xcodeproj/project.pbxproj")
        let text = try String(contentsOf: project, encoding: .utf8)
        XCTAssertTrue(text.contains("USSHStack"), "夹具失效：没读到工程文件")
        XCTAssertFalse(text.contains("USSHTestServer"), "工程里有 target 直接链了 USSHTestServer")
    }

    private static func swiftFiles() throws -> [URL] {
        var out: [URL] = []
        for root in productionRoots {
            let dir = DefaultsKeyLintTests.repoRoot.appendingPathComponent(root)
            guard let enumerator = FileManager.default.enumerator(
                at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                // 本地包里自带的测试目录不算生产源码。
                if url.path.contains("/Tests/") || url.path.contains("/.build/") { continue }
                out.append(url)
            }
        }
        return out
    }
}
