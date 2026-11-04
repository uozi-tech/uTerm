import Network
import SwiftUI
import XCTest
@testable import uTermMobile

/// 与 Mac 上的联调服务（`RemoteSimulatorHarnessTests`，带 `UTERM_HARNESS_FOLLOW=1`）跑一遍真实的接管与跟进。
/// 默认跳过：经 `xcodebuild test-without-building` 传 `TEST_RUNNER_UTERM_HARNESS_PORT=<端口>` 时才运行。
/// 模拟器与 Mac 共用网络栈，直连 127.0.0.1，不需要「本地网络」权限。
@MainActor
final class RemoteFollowRealMacTests: XCTestCase {

    func testTabsFollowTerminalsOpenedAndClosedOnMac() async throws {
        guard let raw = ProcessInfo.processInfo.environment["UTERM_HARNESS_PORT"],
              let port = NWEndpoint.Port(raw) else {
            throw XCTSkip("没有设置 UTERM_HARNESS_PORT，跳过")
        }
        let client = RemoteMacClient(macName: "联调 Mac", endpoint: .hostPort(host: "127.0.0.1", port: port),
                                     identity: RemoteIdentityStore(storage: RemoteMemoryStorage()))
        let store = MobileStore()
        let workspace = MobileWorkspace()
        let (window, _) = MobileProbeWindow.make(
            size: CGSize(width: 390, height: 844),
            rootView: AnyView(WorkspaceScreen()
                .environment(store)
                .environment(HostKeyChallengeRelay())
                .environment(workspace)
                .modelContainer(try MobileFixtures.emptyContainer())))
        defer { window.isHidden = true }

        await client.connect()
        XCTAssertEqual(client.state, .connected)
        try await waitUntil { client.sessions.count == 1 }
        let first = try XCTUnwrap(client.sessions.first?.id)

        store.takeOver(client, focus: first)
        try await waitUntil { workspace.terminalTabs.first?.controller.state == .connected }
        store.finishConnect()
        let front = try XCTUnwrap(workspace.activeTab?.id)

        try await waitUntil { workspace.terminalTabs.count == 2 }
        let added = try XCTUnwrap(workspace.terminalTabs.last)
        try await waitUntil { added.controller.state == .connected }
        XCTAssertEqual(workspace.activeTab?.id, front, "新终端不抢前台")
        XCTAssertFalse(workspace.isFront(added.id))
        XCTAssertEqual(added.hostName, "zsh · 新开")

        try await waitUntil { workspace.terminalTabs.count == 1 }
        XCTAssertNil(workspace.tab(added.id), "Mac 上关掉的终端，手机标签跟着关")
        XCTAssertEqual(workspace.activeTab?.id, front)
        XCTAssertEqual(added.controller.state, .closed)

        // Mac 上终端全关：回到主机列表，接管还在。这时断线也要连回去，否则收不到之后新开的终端。
        try await waitUntil { workspace.isEmpty }
        XCTAssertFalse(store.showWorkspace)
        XCTAssertEqual(workspace.followedClients.count, 1)
        client.disconnect()
        try await waitUntil { client.state != .connected }
        try await waitUntil { client.state == .connected }

        try await waitUntil { workspace.terminalTabs.count == 1 }
        let reopened = try XCTUnwrap(workspace.terminalTabs.first)
        XCTAssertEqual(reopened.hostName, "zsh · 又开")
        try await waitUntil { reopened.controller.state == .connected }
        try await waitUntil { client.sessions.first?.controlledBy != nil }

        // 手动断开全部：标签关掉，Mac 恢复，不再跟进。
        workspace.stopFollowing(client)
        store.teardownTabIDs = workspace.remoteTabIDs(of: client)
        try await waitUntil { workspace.isEmpty }
        XCTAssertTrue(workspace.followedClients.isEmpty)
        try await waitUntil { client.sessions.first?.controlledBy == nil }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !condition() {
            guard Date() < deadline else { return XCTFail("等待超时") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
