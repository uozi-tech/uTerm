import Network
import SwiftUI
import XCTest
@testable import uTermMobile

/// 接管 Mac 的收尾：列表暂时没有、手动关掉最后一个标签、断开全部。
/// 开标签与跟进的规则在 `MobileWorkspaceTests`。
@MainActor
final class MobileTakeoverEndTests: XCTestCase {
    private func macClient(_ name: String = "测试 Mac") -> RemoteMacClient {
        RemoteMacClient(macName: name, endpoint: .hostPort(host: "127.0.0.1", port: 1),
                        identity: RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage()))
    }

    private func takeOver(_ workspace: MobileWorkspace, _ client: RemoteMacClient, _ ids: [UUID]) {
        _ = workspace.takeOver(MRemoteTakeover(client: client, sessionIDs: ids, focus: ids[0]))
    }

    // MARK: - 列表暂时没有

    func testNoListKeepsEveryTab() throws {
        let workspace = MobileWorkspace()
        let client = macClient()
        let ids = [UUID(), UUID()]
        takeOver(workspace, client, ids)
        _ = workspace.follow(client, sessionIDs: ids)

        let changes = workspace.follow(client, sessionIDs: nil)

        XCTAssertTrue(changes.removed.isEmpty, "断线时列表为 nil，不等于 Mac 上的终端都关了")
        XCTAssertTrue(changes.opened.isEmpty)
        XCTAssertEqual(workspace.tabs.count, 2)
        XCTAssertEqual(workspace.followedClients.count, 1)
    }

    func testListComingBackAfterDisconnectChangesNothing() {
        let workspace = MobileWorkspace()
        let client = macClient()
        let ids = [UUID(), UUID()]
        takeOver(workspace, client, ids)
        _ = workspace.follow(client, sessionIDs: ids)
        _ = workspace.follow(client, sessionIDs: nil)

        let changes = workspace.follow(client, sessionIDs: ids)

        XCTAssertTrue(changes.removed.isEmpty)
        XCTAssertTrue(changes.opened.isEmpty, "重连后同一份列表不重复开")
    }

    func testEmptyListAfterDisconnectStillClosesWhatWasListed() {
        let workspace = MobileWorkspace()
        let client = macClient()
        let id = UUID()
        takeOver(workspace, client, [id])
        _ = workspace.follow(client, sessionIDs: [id])
        _ = workspace.follow(client, sessionIDs: nil)

        XCTAssertEqual(workspace.follow(client, sessionIDs: []).removed.count, 1)
        XCTAssertTrue(workspace.isEmpty)
        XCTAssertEqual(workspace.followedClients.count, 1, "Mac 那边关光的不算断开")
    }

    func testFirstEmptyListDoesNotCloseJustOpenedShell() {
        let workspace = MobileWorkspace()
        let client = macClient()
        takeOver(workspace, client, [UUID()])

        XCTAssertTrue(workspace.follow(client, sessionIDs: []).removed.isEmpty, "刚开的 shell 可能排在列表更新之前")
        XCTAssertEqual(workspace.tabs.count, 1)
    }

    func testClientThatNeverConnectedHasNoListAndMayConnect() {
        let client = macClient()
        XCTAssertNil(client.listedSessionIDs)
        XCTAssertTrue(client.canAutoReconnect)
    }

    // MARK: - 手动关掉最后一个标签

    /// 按工作区屏的顺序：先摘标签，再判断是不是最后一个。
    private func closeByHand(_ workspace: MobileWorkspace, _ id: UUID) throws {
        let removed = try XCTUnwrap(workspace.close(id))
        workspace.stopFollowingIfLastTab(removed)
    }

    func testClosingTheLastTabByHandEndsTheTakeover() throws {
        let workspace = MobileWorkspace()
        let client = macClient()
        let ids = [UUID(), UUID()]
        takeOver(workspace, client, ids)
        let tabs = workspace.tabs.map(\.id)

        try closeByHand(workspace, tabs[0])
        XCTAssertEqual(workspace.followedClients.count, 1, "还有别的标签，继续跟进")

        try closeByHand(workspace, tabs[1])
        XCTAssertTrue(workspace.followedClients.isEmpty)
        XCTAssertTrue(workspace.follow(client, sessionIDs: ids + [UUID()]).opened.isEmpty, "断开之后不再开回来")
    }

    func testClosingOneMacsLastTabLeavesTheOtherMacFollowed() throws {
        let workspace = MobileWorkspace()
        let first = macClient("第一台")
        let second = macClient("第二台")
        takeOver(workspace, first, [UUID()])
        takeOver(workspace, second, [UUID()])
        let firstTab = try XCTUnwrap(workspace.remoteTabIDs(of: first).first)

        try closeByHand(workspace, firstTab)

        XCTAssertEqual(workspace.followedClients.map(\.macName), ["第二台"])
    }

    func testClosingADirectTabLeavesTheTakeoverAlone() throws {
        let workspace = MobileWorkspace()
        let client = macClient()
        takeOver(workspace, client, [UUID()])
        let (direct, _) = MobileFakeTerminal.tab(host: ServerProfile(), .idle)
        workspace.open(.terminal(direct))

        try closeByHand(workspace, direct.id)

        XCTAssertEqual(workspace.followedClients.count, 1)
    }

    // MARK: - 断开全部

    func testEndingATakeoverReturnsOnlyThatMacsTabs() {
        let workspace = MobileWorkspace()
        let first = macClient("第一台")
        let second = macClient("第二台")
        takeOver(workspace, first, [UUID(), UUID()])
        takeOver(workspace, second, [UUID()])
        let firstTabs = workspace.remoteTabIDs(of: first)

        XCTAssertEqual(workspace.endTakeover(of: first), firstTabs)
        XCTAssertEqual(workspace.followedClients.map(\.macName), ["第二台"])
    }

    /// 「断开全部终端」「忘记这台 Mac」走的整条路：工作区屏真的关掉标签、收回主机列表。
    func testWorkspaceTearsDownTheTabsOfAnEndedTakeover() async throws {
        defer { MobileProbeWindow.closeAll() }
        let first = macClient("第一台")
        let second = macClient("第二台")
        let store = MobileStore()
        store.showWorkspace = true
        let workspace = MobileWorkspace()
        _ = MobileProbeWindow.make(size: CGSize(width: 390, height: 844), rootView: AnyView(WorkspaceScreen()
            .environment(store)
            .environment(HostKeyChallengeRelay())
            .environment(workspace)
            .modelContainer(try MobileFixtures.emptyContainer())))
        store.remoteTakeover = MRemoteTakeover(client: first, sessionIDs: [UUID(), UUID()], focus: UUID())
        try await waitUntil { workspace.tabs.count == 2 }
        store.remoteTakeover = MRemoteTakeover(client: second, sessionIDs: [UUID()], focus: UUID())
        try await waitUntil { workspace.tabs.count == 3 }

        store.teardownTabIDs = workspace.endTakeover(of: first)
        try await waitUntil { workspace.tabs.count == 1 }
        XCTAssertTrue(store.showWorkspace, "另一台 Mac 的标签还在")
        XCTAssertTrue(store.teardownTabIDs.isEmpty)
        XCTAssertEqual(workspace.followedClients.map(\.macName), ["第二台"])

        // 隔开一帧：工作区屏清空 teardownTabIDs 本身也触发一次 onChange，同一帧里再改一次会被 SwiftUI 丢掉
        // （「onChange tried to update multiple times per frame」）。人点不出同一帧的两次断开。
        try await Task.sleep(for: .milliseconds(100))
        store.teardownTabIDs = workspace.endTakeover(of: second)
        try await waitUntil { workspace.isEmpty }
        try await waitUntil { !store.showWorkspace }
        XCTAssertTrue(workspace.followedClients.isEmpty)
    }

    private func waitUntil(_ condition: () -> Bool, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() {
            guard Date() < deadline else { return XCTFail("等待超时", line: line) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
