import XCTest
@testable import uTerm

/// 引擎版本串和二进制清单对得上。
///
/// `TerminalEngineVersion.current` 是手写的：远控握手靠它判断两端是不是同一个引擎，holder 检查点靠它判断是不是这一版存的。
/// 二进制由 `vendor/libghostty-spm/ENGINE.lock` 定（`make engine` 按它取）。换了二进制、清单里的 `engine_version` 改了、
/// 常量忘了改（或者反过来），两端会拿着不同的引擎互认快照——这条用例拦的就是这个。
/// 升级步骤见 `vendor/libghostty-spm/UTERM-PATCHES.md`。iOS 那边有同样的一条。
final class TerminalEngineLockTests: XCTestCase {

    func testEngineVersionMatchesTheBinaryLock() throws {
        let lock = try Self.lock()
        XCTAssertEqual(lock["engine_version"], TerminalEngineVersion.current, """
            vendor/libghostty-spm/ENGINE.lock 的 engine_version 和 TerminalEngineVersion.current 不一致。
            换引擎二进制时两处要一起改（uTerm/Features/Terminal/Shadow/TerminalEngineVersion.swift）。
            """)
    }

    /// 清单里取二进制要的每一项都在、sha256 的形状对，免得上一条因为读错文件而空过。
    func testLockListsBothBinaries() throws {
        let lock = try Self.lock()
        for id in ["ghosttykit", "ghosttyvt"] {
            XCTAssertEqual(lock["\(id)_zip"]?.hasSuffix(".xcframework.zip"), true, "\(id)_zip")
            XCTAssertEqual(lock["\(id)_dir"]?.hasSuffix(".xcframework"), true, "\(id)_dir")
            let sha = try XCTUnwrap(lock["\(id)_sha256"], "\(id)_sha256")
            XCTAssertNotNil(sha.wholeMatch(of: /[0-9a-f]{64}/), "\(id)_sha256 不是 64 位小写十六进制：\(sha)")
        }
        XCTAssertNil(lock["download_base"], "二进制还没上传：download_base 应当保持注释状态，脚本不联网")
    }

    /// 版本串里写的 Ghostty 提交、补丁编号和清单里的来源、zip 文件名是同一回事。
    func testEngineVersionNamesTheSameCommitAndPatchLevel() throws {
        let lock = try Self.lock()
        let version = TerminalEngineVersion.current
        let parts = try XCTUnwrap(version.wholeMatch(of: /ghostty-([0-9a-f]{8})\+p(\d{4})\/snapshot-(\d+)/),
                                  "版本串的形状变了：\(version)")
        let commit = try XCTUnwrap(lock["ghostty_commit"])
        XCTAssertTrue(commit.hasPrefix(String(parts.1)), "版本串里的提交 \(parts.1) 不是清单里的 ghostty_commit \(commit)")
        let zip = try XCTUnwrap(lock["ghosttykit_zip"])
        XCTAssertTrue(zip.contains("-\(parts.2)."), "版本串里的补丁编号 p\(parts.2) 和 GhosttyKit 的 zip（\(zip)）对不上")
    }

    // MARK: - 读清单

    private static func lock() throws -> [String: String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Terminal
            .deletingLastPathComponent()   // Features
            .deletingLastPathComponent()   // uTermTests
            .deletingLastPathComponent()   // 仓库根
            .appendingPathComponent("vendor/libghostty-spm/ENGINE.lock")
        let text = try String(contentsOf: url, encoding: .utf8)
        var values: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { continue }
            values[String(trimmed[..<equals])] = String(trimmed[trimmed.index(after: equals)...])
        }
        XCTAssertFalse(values.isEmpty, "没读到任何键：\(url.path)")
        return values
    }
}
