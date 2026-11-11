import SwiftData
import XCTest
@testable import uTermMobile

/// 真 sshd 上的整条链路：产品的终端标签（真的后端、真的终端）连上主机，进后台、App 没了，
/// 再凭标签归档开回来——画面回来、shell 还是原来那个。
///
/// 默认跳过。需要一台 Linux（amd64 / arm64）的测试 sshd，密码登录；和 Mac 侧 `PersistentSSHConnectionLiveTests`
/// 用同一个容器（`holder/e2e/sshd`）即可，模拟器和宿主机共用网络：
///
///     TEST_RUNNER_UTERM_LIVE_SSH_PORT=2298 TEST_RUNNER_UTERM_LIVE_SSH_USER=dev \
///     TEST_RUNNER_UTERM_LIVE_SSH_PASSWORD=dev xcodebuild test … \
///       -only-testing:uTermMobileTests/MobileTerminalLiveHostSessionTests
///
/// 钥匙串条目用新造的主机 id，用例结束即删。
@MainActor
final class MobileTerminalLiveHostSessionTests: XCTestCase {
    private var container: ModelContainer!
    private var profile: ServerProfile!
    private let relay = HostKeyChallengeRelay()

    override func setUp() async throws {
        try await super.setUp()
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["UTERM_LIVE_SSH_PORT"], let port = Int(raw) else {
            throw XCTSkip("没设 UTERM_LIVE_SSH_PORT，跳过真 sshd 用例")
        }
        container = try MobileFixtures.emptyContainer()
        profile = ServerProfile()
        profile.name = "holder-live"
        profile.host = env["UTERM_LIVE_SSH_HOST"] ?? "127.0.0.1"
        profile.port = port
        profile.username = env["UTERM_LIVE_SSH_USER"] ?? "root"
        profile.authMethod = .password
        container.mainContext.insert(profile)
        try container.mainContext.save()
        let keychain = KeychainStore()
        try keychain.save(env["UTERM_LIVE_SSH_PASSWORD"] ?? "PASS", profileID: profile.id, kind: .password)
        let id = profile.id
        addTeardownBlock { try? KeychainStore().delete(profileID: id, kind: .password) }
    }

    /// 等条件成立；期间出现的主机密钥确认一律信任（只对测试服务器）。
    private func wait(_ what: String, timeout: Duration = .seconds(30), until done: () -> Bool,
                      file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + timeout
        while !done() {
            if relay.pendingChallenge != nil { relay.resolve(true) }
            guard ContinuousClock.now < deadline else {
                XCTFail("等不到：\(what)", file: file, line: line)
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func screen(_ tab: TermTab) -> String { tab.controller.terminal.shadow.viewportText() }

    private func shellPID(on tab: TermTab, marker: String) -> String? {
        let text = screen(tab)
        guard let range = text.range(of: "\(marker)=[0-9]+", options: .regularExpression) else { return nil }
        return String(text[range].dropFirst(marker.count + 1))
    }

    func testTabComesBackWithItsScreenAfterTheAppIsGone() async throws {
        let suite = "MobileTerminalLiveHostSessionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }

        // 第一次运行：开标签、连上、屏幕上有内容。
        var workspace: MobileWorkspace? = MobileWorkspace()
        var first: TermTab? = TermTab(host: profile)
        first!.controller.start(profile: profile, container: container, relay: relay)
        workspace!.open(.terminal(first!))
        await wait("连上") { first!.controller.state == .connected }
        first!.controller.sendText("stty -echo; clear; echo PID=$$; echo first-run-line\n")
        await wait("第一次运行的输出") { self.screen(first!).contains("first-run-line") }
        let pid = try XCTUnwrap(shellPID(on: first!, marker: "PID"))
        let sessionID = first!.controller.hostSessionID

        // 进后台：标签记进归档，终端状态存到主机上。
        workspace!.terminalTabArchive(showsWorkspace: true).save(to: defaults)
        first!.controller.appVisibilityChanged(inBackground: true)
        try await Task.sleep(for: .milliseconds(800))
        // 后台那段时间里主机上又有输出。
        first!.controller.sendText("echo after-background\n")
        await wait("进后台之后的输出") { self.screen(first!).contains("after-background") }

        // App 没了：标签、控制器、终端全丢掉，没人去关会话。
        first = nil
        workspace = nil
        MobileBackgroundGrace.shared.end()

        // 重新打开：凭归档把标签开回来。
        let archive = MobileTerminalTabArchive.load(from: defaults)
        XCTAssertEqual(archive.tabs, [.init(hostID: profile.id, sessionID: sessionID)])
        XCTAssertTrue(archive.showsWorkspace)
        let reopened = MobileWorkspace()
        let opened = archive.restore(into: reopened, hosts: [profile]) { term in
            term.controller.start(profile: term.host, container: self.container, relay: self.relay)
        }
        let second = try XCTUnwrap(opened.first)
        XCTAssertEqual(second.controller.hostSessionID, sessionID)
        await wait("接回") { second.controller.state == .connected }
        await wait("屏幕回来了") {
            self.screen(second).contains("first-run-line") && self.screen(second).contains("after-background")
        }

        // 还是原来那个 shell，而且能接着用。
        second.controller.sendText("echo AGAIN=$$\n")
        await wait("同一个 shell") { self.shellPID(on: second, marker: "AGAIN") == pid }

        // 关标签：主机上的会话随之结束。
        second.controller.sendText("echo closing\n")
        await wait("关之前的输出") { self.screen(second).contains("closing") }
        reopened.close(second.id)
        second.controller.close()
        XCTAssertTrue(reopened.terminalTabArchive(showsWorkspace: false).tabs.isEmpty)
    }
}
