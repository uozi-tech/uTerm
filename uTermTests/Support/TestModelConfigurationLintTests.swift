import Foundation
import XCTest

/// 测试源码 lint：测试里建的每个 `ModelConfiguration(...)` 都必须显式写 `cloudKitDatabase:`。
///
/// ## 为什么
///
/// `ModelConfiguration` 的 `cloudKitDatabase` 默认是 `.automatic`，**内存库也不例外**。
/// 测试 target 挂在 `uTerm.app` 宿主里跑，带着 `iCloud.com.uozi.uTerm` 容器
/// 与 `icloud-container-environment = Production` 的 entitlement，于是
/// `NSCloudKitMirroringDelegate` 会把测试插进内存库的假数据**照常导出到 iCloud 生产库**，
/// 再被正式版（以及 iOS 端）导入——2026-09-15 两轮测试就这样往正式版灌了
/// 150 多个 `prod-web` / `192.0.2.x` / `10.0.0.x` 假服务器和几十条假转发规则。
///
/// 编译期没有任何信号，只能靠 lint 钉。
final class TestModelConfigurationLintTests: XCTestCase {

    func testEveryTestModelConfigurationDisablesCloudKit() throws {
        var offenders: [String] = []
        var scanned = 0

        for file in try Self.testSwiftFiles() where file.lastPathComponent != "TestModelConfigurationLintTests.swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            for call in Self.calls(of: "ModelConfiguration(", in: source) {
                scanned += 1
                if !call.args.contains("cloudKitDatabase") {
                    offenders.append("\(file.lastPathComponent):\(call.line)")
                }
            }
        }

        XCTAssertGreaterThan(scanned, 10, "夹具失效：测试源码里应该有几十处 ModelConfiguration(")
        XCTAssertTrue(offenders.isEmpty, """
            测试里的 ModelConfiguration 没写 cloudKitDatabase（\(offenders.count) 处）：
            \(offenders.joined(separator: "\n"))
            默认 .automatic 会把测试数据（内存库也会）同步进 iCloud 生产库，出现在正式版里。
            加上 `cloudKitDatabase: .none`。
            """)
    }

    /// 测试宿主和正式版共用一份设置：写 `AccentState.shared` 等于改用户选的强调色，
    /// 用例收尾设回蓝色，用户下次启动就发现颜色变了。
    func testNoTestWritesSharedAccentState() throws {
        var offenders: [String] = []
        for file in try Self.testSwiftFiles() {
            let source = try String(contentsOf: file, encoding: .utf8)
            for match in source.matches(of: /AccentState\.shared\.selected\s*=[^=]/) {
                let line = source[..<match.range.lowerBound].filter { $0 == "\n" }.count + 1
                offenders.append("\(file.lastPathComponent):\(line)")
            }
        }
        XCTAssertTrue(offenders.isEmpty, """
            测试写了 AccentState.shared（\(offenders.count) 处）：
            \(offenders.joined(separator: "\n"))
            改用 `AccentState(defaults:)` 配私有 UserDefaults 套件。
            """)
    }

    /// macOS 测试宿主用的就是正式版的设置。写跨设备同步的键等于改掉用户的选择，
    /// 正式版下次读到的就是测试留下的值。
    func testNoMacTestWritesSyncedPreference() throws {
        let sync = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("uTerm/Core/Sync/SharedPreferencesSync.swift"),
            encoding: .utf8)
        // 清单写的是 `PreferenceKey.xxx`，键名的字面量在键名表里，按常量名查回去。
        let table = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("uTerm/Core/Preferences/PreferenceKey.swift"),
            encoding: .utf8)
        let values = Dictionary(
            table.matches(of: /static let (\w+) = "([^"]+)"/).map { (String($0.output.1), String($0.output.2)) },
            uniquingKeysWith: { first, _ in first })
        let keys = sync.matches(of: /Definition\(key: PreferenceKey\.(\w+)/).compactMap { values[String($0.output.1)] }
        XCTAssertGreaterThan(keys.count, 10, "夹具失效：应该能从同步清单读到十几个键")

        var offenders: [String] = []
        for file in try Self.testSwiftFiles() where file.path.contains("/uTermTests/") {
            let source = try String(contentsOf: file, encoding: .utf8)
            for match in source.matches(of: /UserDefaults\.standard\.(?:set|removeObject)\([^"\n]*"([^"\n]+)"/)
            where keys.contains(String(match.output.1)) {
                let line = source[..<match.range.lowerBound].filter { $0 == "\n" }.count + 1
                offenders.append("\(file.lastPathComponent):\(line) \(match.output.1)")
            }
        }
        XCTAssertTrue(offenders.isEmpty, """
            测试写了跨设备同步的设置（\(offenders.count) 处）：
            \(offenders.joined(separator: "\n"))
            把值作为参数注入，或改用私有 UserDefaults 套件。
            """)
    }

    // MARK: - 扫描

    /// 找出 `name` 的每次调用，按括号深度截出参数文本（支持跨行）。
    static func calls(of name: String, in source: String) -> [(line: Int, args: String)] {
        var out: [(Int, String)] = []
        var searchStart = source.startIndex
        while let r = source.range(of: name, range: searchStart..<source.endIndex) {
            var depth = 1
            var i = r.upperBound
            while i < source.endIndex, depth > 0 {
                switch source[i] {
                case "(": depth += 1
                case ")": depth -= 1
                default: break
                }
                i = source.index(after: i)
            }
            let line = source[..<r.lowerBound].filter { $0 == "\n" }.count + 1
            out.append((line, String(source[r.upperBound..<i])))
            searchStart = i
        }
        return out
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Support
            .deletingLastPathComponent()   // uTermTests
            .deletingLastPathComponent()   // repo
    }

    /// `uTermTests/` 与 `uTermMobileTests/` 下的全部 .swift。
    static func testSwiftFiles() throws -> [URL] {
        var out: [URL] = []
        for root in ["uTermTests", "uTermMobileTests"] {
            let dir = repoRoot.appendingPathComponent(root)
            guard let e = FileManager.default.enumerator(
                at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
            for case let url as URL in e where url.pathExtension == "swift" {
                out.append(url)
            }
        }
        return out.sorted { $0.path < $1.path }
    }
}
