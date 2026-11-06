import Foundation
import XCTest

/// 生产源码 lint：偏好键名只许出自 `PreferenceKey`（`uTerm/Core/Preferences/PreferenceKey.swift`）。
///
/// ## 为什么
///
/// 键名散在两端各写一份字面量时，一边手滑（或「顺手改个更好的名字」）编译期毫无信号，
/// 结果是那项设置在该端被清零、iCloud KVS / 局域网同步按键名对不上——两端各说各话。
/// 集中到一张表后再用这条 lint 拦住新写的裸字面量。
final class PreferenceKeyLintTests: XCTestCase {

    /// 还没接线到 `PreferenceKey` 的文件（本轮别的改动在动它们）。接好后从这里删掉。
    private static let pendingFiles: Set<String> = [
        "uTerm/Features/Files/FileBrowserModel.swift",
    ]

    func testNoRawAppStorageKeyLiterals() throws {
        let offenders = try Self.scan(pattern: /@AppStorage\(\s*"/)
        XCTAssertTrue(offenders.isEmpty, """
            生产代码里有裸的 @AppStorage("…") 键名（\(offenders.count) 处）：
            \(offenders.joined(separator: "\n"))
            把键加进 PreferenceKey（值保持原样），这里改成 @AppStorage(PreferenceKey.xxx)。
            """)
    }

    func testNoRawUserDefaultsKeyLiterals() throws {
        let offenders = try Self.scan(
            pattern: /(?:defaults|UserDefaults\.standard)\.(?:set|object|string|bool|integer|double|array|stringArray|dictionary|data|removeObject)\([^\n]*forKey:\s*"/,
            skipping: Self.pendingFiles)
        XCTAssertTrue(offenders.isEmpty, """
            生产代码里有裸的 UserDefaults 键名（\(offenders.count) 处）：
            \(offenders.joined(separator: "\n"))
            把键加进 PreferenceKey（值保持原样），这里改成 forKey: PreferenceKey.xxx。
            """)
    }

    /// 夹具自检：确实扫到了两端的源码与大量 @AppStorage。
    func testScannerSeesProductionSources() throws {
        let files = try Self.productionSwiftFiles()
        XCTAssertGreaterThan(files.count, 300)
        XCTAssertTrue(files.contains { $0.path.contains("/uTermMobile/") })
        let uses = try files.reduce(0) { total, file in
            total + (try String(contentsOf: file, encoding: .utf8)).matches(of: /@AppStorage\(PreferenceKey\./).count
        }
        XCTAssertGreaterThan(uses, 20, "夹具失效：应当有二十多处 @AppStorage(PreferenceKey.…)")
    }

    // MARK: - 扫描

    /// 非注释行里匹配 `pattern` 的位置（`相对路径:行号`）。
    private static func scan(pattern: Regex<Substring>, skipping: Set<String> = []) throws -> [String] {
        var offenders: [String] = []
        let rootPath = repoRoot.path + "/"
        for file in try productionSwiftFiles() {
            let relative = file.path.replacingOccurrences(of: rootPath, with: "")
            guard !skipping.contains(relative) else { continue }
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"), line.contains(pattern) else { continue }
                offenders.append("\(relative):\(index + 1)")
            }
        }
        return offenders
    }

    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Support
            .deletingLastPathComponent()   // uTermTests
            .deletingLastPathComponent()   // repo
    }

    /// `uTerm/` 与 `uTermMobile/` 下的全部 .swift（两个 app target 的生产源码）。
    static func productionSwiftFiles() throws -> [URL] {
        var out: [URL] = []
        for root in ["uTerm", "uTermMobile"] {
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
