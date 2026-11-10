import XCTest
@testable import uTermMobile

/// 引擎版本串和二进制清单对得上（Mac 那边 `uTermTests/Features/Terminal/TerminalEngineLockTests.swift` 有同样的一条）。
///
/// `TerminalEngineVersion.current` 是手写的：手机接 Mac 的终端时握手里带着它，两端不同就拒绝镜像。二进制由
/// `vendor/libghostty-spm/ENGINE.lock` 定。换了二进制忘了改常量，新旧引擎会互认快照——这条用例拦的就是这个。
/// 升级步骤见 `vendor/libghostty-spm/UTERM-PATCHES.md`。
final class TerminalEngineLockTests: XCTestCase {

    func testEngineVersionMatchesTheBinaryLock() throws {
        #if !targetEnvironment(simulator)
            throw XCTSkip("清单在开发机的仓库里，真机上读不到；这条在模拟器上跑")
        #else
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()   // uTermMobileTests
                .deletingLastPathComponent()   // 仓库根
                .appendingPathComponent("vendor/libghostty-spm/ENGINE.lock")
            let text = try String(contentsOf: url, encoding: .utf8)
            let versions = text.components(separatedBy: .newlines)
                .filter { $0.hasPrefix("engine_version=") }
                .map { String($0.dropFirst("engine_version=".count)).trimmingCharacters(in: .whitespaces) }
            XCTAssertEqual(versions, [TerminalEngineVersion.current], """
                vendor/libghostty-spm/ENGINE.lock 的 engine_version 和 TerminalEngineVersion.current 不一致。
                换引擎二进制时两处要一起改（uTerm/Features/Terminal/Shadow/TerminalEngine.swift）。
                """)
        #endif
    }
}
