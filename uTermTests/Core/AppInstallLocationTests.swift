import Foundation
import XCTest
@testable import uTerm

/// 只有装好的那一份 uTerm（/Applications 或 ~/Applications 里）才对齐技能链接、注册中继。
/// 回归 2026-11-08：worktree 的 Debug 构建被 utermctl 按需拉起后以本机身份注册中继，把已安装的 uTerm 顶掉。
@MainActor
final class AppInstallLocationTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

    private func installed(_ path: String) -> Bool {
        AppInstallLocation.isInstalled(bundleURL: URL(fileURLWithPath: path, isDirectory: true), home: home)
    }

    func test_applications_folders_count_as_installed() {
        XCTAssertTrue(installed("/Applications/uTerm.app"))
        XCTAssertTrue(installed("/Applications/Utilities/uTerm.app"), "子文件夹也算")
        XCTAssertTrue(installed("/Users/someone/Applications/uTerm.app"))
    }

    func test_build_products_and_lookalike_paths_do_not() {
        XCTAssertFalse(installed("/Users/someone/Workspace/uTerm/.claude/worktrees/x/build/DerivedData/Build/Products/Debug/uTerm.app"))
        XCTAssertFalse(installed("/Users/someone/Library/Developer/Xcode/DerivedData/uTerm-abc/Build/Products/Release/uTerm.app"))
        XCTAssertFalse(installed("/Applications.backup/uTerm.app"), "只认那两个文件夹本身")
        XCTAssertFalse(installed("/Volumes/uTerm/uTerm.app"), "直接从 DMG 里打开")
        XCTAssertFalse(installed("/Users/other/Applications/uTerm.app"), "别人的家目录")
    }

    func test_dev_build_relay_needs_an_explicit_launch_argument() {
        XCTAssertFalse(AppInstallLocation.allowsDevBuildRelay(arguments: ["uTerm"]))
        XCTAssertFalse(AppInstallLocation.allowsDevBuildRelay(arguments: ["uTerm", "-RemoteRelayAllowDevBuild"]))
        XCTAssertFalse(AppInstallLocation.allowsDevBuildRelay(arguments: ["uTerm", "-RemoteRelayAllowDevBuild", "NO"]))
        XCTAssertTrue(AppInstallLocation.allowsDevBuildRelay(arguments: ["uTerm", "-RemoteRelayAllowDevBuild", "YES"]))
    }

    func test_registration_block_by_process_kind() {
        typealias Block = RemoteRelayRegistrationBlock
        XCTAssertNil(Block.current(isTestHost: false, isInstalled: true, arguments: []))
        XCTAssertEqual(Block.current(isTestHost: false, isInstalled: false, arguments: []), .developmentBuild)
        XCTAssertNil(Block.current(isTestHost: false, isInstalled: false,
                                   arguments: ["uTerm", "-RemoteRelayAllowDevBuild", "YES"]), "联调中继时显式放开")
        XCTAssertEqual(Block.current(isTestHost: true, isInstalled: true,
                                     arguments: ["uTerm", "-RemoteRelayAllowDevBuild", "YES"]), .testHost,
                       "测试宿主怎样都不注册")
    }

    func test_blocked_server_never_creates_a_relay_link() throws {
        let config = RemoteRelayConfig(name: "本机", host: "127.0.0.1", port: 9, relayID: "abc",
                                       key: Data(repeating: 1, count: 32).base64EncodedString())
        for block in [RemoteRelayRegistrationBlock.developmentBuild, .testHost] {
            let server = RemoteHostServer(registry: TerminalSessionRegistry(),
                                          identity: RemoteIdentityStore(role: .controllers, storage: RemoteMemoryStorage()),
                                          localID: UUID(), advertises: false, relayRegistrationBlock: block)
            server.relayConfig = config
            server.updateInternetAccess(enabled: true, keepAwake: false)
            XCTAssertNil(server.relayLink, "\(block) 不该注册中继")
        }
        let server = RemoteHostServer(registry: TerminalSessionRegistry(),
                                      identity: RemoteIdentityStore(role: .controllers, storage: RemoteMemoryStorage()),
                                      localID: UUID(), advertises: false)
        server.relayConfig = config
        server.updateInternetAccess(enabled: true, keepAwake: false)
        XCTAssertNotNil(server.relayLink, "装好的那一份照常注册")
        server.updateInternetAccess(enabled: false, keepAwake: false)
    }

    func test_test_host_is_not_treated_as_installed_build() {
        // 测试宿主在 DerivedData 里：本身就不是装好的那一份。
        XCTAssertFalse(AppInstallLocation.isCurrentInstalled)
    }
}
