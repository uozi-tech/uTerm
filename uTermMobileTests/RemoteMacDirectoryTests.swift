import CryptoKit
@preconcurrency import Network
import SwiftUI
import UIKit
import XCTest
@testable import uTermMobile

/// 「我的 Mac」只列本机配对过的 Mac，按设备 ID 对号在线状态；局域网里没配对的列进「附近的 Mac」，
/// 点了走审批配对。新建终端抽屉只列配对过且在线的。
@MainActor
final class RemoteMacDirectoryTests: XCTestCase {
    private static let macName = "调试 Mac（127.0.0.1:1）"

    /// 带调试直连地址的目录（调试 Mac 事先不知道身份，总是列出、总是算在线）。
    private func directory(identity: RemoteIdentityStore = RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage()),
                           debugEndpoint: Bool = true) throws -> RemoteMacDirectory {
        let suite = "RemoteMacDirectoryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        if debugEndpoint { defaults.set("127.0.0.1:1", forKey: "RemoteDebugEndpoint") }
        let directory = RemoteMacDirectory(identity: identity, defaults: defaults)
        directory.activate()
        return directory
    }

    private func key() -> Data { Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation }
    private let somewhere = NWEndpoint.hostPort(host: "192.168.1.9", port: 4000)

    func testListsTrustedMacsAndPutsUnpairedOnlineOnesNearby() {
        let mine = RemotePeer(id: UUID(), name: "MacBook Pro", publicKey: key(), pairedAt: .now)
        let scanned = RemotePeer(id: UUID(), name: "办公室 iMac", publicKey: key(), pairedAt: .now)
        let stranger = UUID()
        let online = RemoteMacDirectory.onlineMacs([
            ("我的 MacBook Pro", mine.id.uuidString, somewhere),
            ("别人的 Mac", stranger.uuidString, somewhere),
            ("老版本 Mac", nil, somewhere),
        ])
        XCTAssertEqual(Set(online.keys), [mine.id, stranger], "没有设备 ID 的结果不认")

        let macs = RemoteMacDirectory.knownMacs(trusted: [scanned, mine], online: online)
        XCTAssertEqual(macs.map(\.deviceID), [mine.id, scanned.id], "只有配对过的 Mac，在线的在前")
        XCTAssertEqual(macs[0].name, "我的 MacBook Pro", "在线时用 Bonjour 上的电脑名（改过名也跟得上）")
        XCTAssertEqual(macs[0].source, .paired)
        XCTAssertTrue(macs[0].isOnline)
        XCTAssertFalse(macs[1].isOnline)
        XCTAssertEqual(macs[0].expectedPeer?.publicKey, mine.publicKey, "连的时候按配对时记下的公钥核对")

        let nearby = RemoteMacDirectory.nearbyMacs(online: online, paired: [mine.id, scanned.id], localID: UUID())
        XCTAssertEqual(nearby.map(\.deviceID), [stranger])
        XCTAssertEqual(nearby.first?.source, .nearby)
        XCTAssertNil(nearby.first?.expectedPeer, "还不知道它的公钥：连上去要在 Mac 上审批")
        XCTAssertTrue(nearby.first?.isOnline ?? false)
    }

    func testNearbyNeverListsThisDevice() {
        let me = UUID(), other = UUID()
        let online = RemoteMacDirectory.onlineMacs([("本机", me.uuidString, somewhere), ("隔壁", other.uuidString, somewhere)])
        let nearby = RemoteMacDirectory.nearbyMacs(online: online, paired: [], localID: me)
        XCTAssertEqual(nearby.map(\.deviceID), [other], "Mac 当主控时 Bonjour 也看得到自己")
    }

    func testSameNameDoesNotMakeAStrangerLookPaired() {
        let mine = RemotePeer(id: UUID(), name: "MacBook Pro", publicKey: key(), pairedAt: .now)
        let online = RemoteMacDirectory.onlineMacs([("MacBook Pro", UUID().uuidString, somewhere)])
        let macs = RemoteMacDirectory.knownMacs(trusted: [mine], online: online)
        XCTAssertEqual(macs.count, 1)
        XCTAssertFalse(macs[0].isOnline, "同名的另一台 Mac 不算我的这台在线")
    }

    func testScanningPairsAndForgettingBlocks() throws {
        let identity = RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage())
        let directory = try directory(identity: identity, debugEndpoint: false)
        let invitation = RemotePairingInvitation(macID: UUID(), macName: "办公室 iMac", macKey: key(),
                                                 token: RemotePairingInvitation.newToken())

        let mac = try XCTUnwrap(try directory.pair(with: invitation))
        XCTAssertEqual(mac.deviceID, invitation.macID)
        XCTAssertFalse(mac.isOnline, "还没在局域网里看到它")
        XCTAssertEqual(identity.peer(id: invitation.macID)?.publicKey, invitation.macKey)
        XCTAssertEqual(directory.client(for: mac).pairingToken, invitation.token, "下次连它时带上凭据")

        directory.forget(mac)
        XCTAssertTrue(directory.macs.isEmpty)
        XCTAssertTrue(identity.isBlocked(invitation.macID))
        XCTAssertNotNil(try directory.pair(with: invitation), "重新扫码可以再配上")
        XCTAssertFalse(identity.isBlocked(invitation.macID))
    }

    func testPairedButOfflineMacIsListedButNotOfferedForNewTerminals() throws {
        let identity = RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage())
        let peer = RemotePeer(id: UUID(), name: "MacBook Pro", publicKey: key(), pairedAt: .now)
        try identity.trust(peer)
        let directory = try directory(identity: identity, debugEndpoint: false)
        XCTAssertEqual(directory.macs.map(\.deviceID), [peer.id])
        XCTAssertTrue(directory.pairedMacs.isEmpty, "不在线的不进新建终端抽屉")
        XCTAssertTrue(directory.nearbyMacs.isEmpty)
    }

    func testDebugEndpointIsOffered() throws {
        let directory = try directory()
        XCTAssertEqual(directory.pairedMacs.map(\.name), [Self.macName])
    }

    func testTabHostForLocalShellIsNotPersistedAndNamedAfterTheMac() throws {
        let directory = try directory()
        let client = directory.client(for: try XCTUnwrap(directory.pairedMacs.first))
        let host = client.tabHost(for: UUID())
        XCTAssertEqual(host.id, RemoteConstants.localShellServerID)
        XCTAssertEqual(host.name, Self.macName)
        XCTAssertNil(host.modelContext)
    }

    /// 工作区真的消费接管请求：全部终端开成标签、连接中页跟前台那个，取消时一个不留。
    func testWorkspaceOpensEveryTerminalAndCancelClosesThemAll() async throws {
        let directory = try directory()
        let client = directory.client(for: try XCTUnwrap(directory.pairedMacs.first))
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

        let ids = [UUID(), UUID(), UUID()]
        store.takeOver(client, focus: ids[1])
        store.remoteTakeover = MRemoteTakeover(client: client, sessionIDs: ids, focus: ids[1])
        let request = try XCTUnwrap(store.connecting)
        try await waitUntil { workspace.tabs.count == 3 }

        XCTAssertEqual(workspace.activeTab?.terminal?.remote?.sessionID, ids[1])
        XCTAssertEqual(request.tabID, workspace.activeTab?.id)
        XCTAssertTrue(request.terminal === workspace.activeTab?.terminal?.controller)
        XCTAssertEqual(request.companionTabIDs.count, 2)

        store.cancelConnect()
        try await waitUntil { workspace.isEmpty }
        XCTAssertFalse(store.showWorkspace)
        XCTAssertTrue(store.teardownTabIDs.isEmpty)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() {
            guard Date() < deadline else { return XCTFail("等待超时") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// 配对过的 Mac 要真的画成一行（抽屉是纯 SwiftUI，这里只验行存在、有名字）。
    func testRowRendersForPairedMac() async throws {
        let directory = try directory()
        let scene = try XCTUnwrap(MobileProbeWindow.activeScene())
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }
        let host = UIHostingController(rootView: VStack {
            MacTerminalRows(directory: directory) { _, _ in }
        }.padding(16))
        window.rootViewController = host
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(300))
        host.view.layoutIfNeeded()
        let size = host.sizeThatFits(in: CGSize(width: 390, height: 400))
        XCTAssertGreaterThan(size.height, 60, "一行至少 38pt 图标 + 内边距")
    }

    // MARK: - 邀请带中继

    private func relay(_ id: String, name: String) -> RemoteRelayConfig {
        RemoteRelayConfig(name: name, host: "\(id).example", port: 47310, relayID: id,
                          key: P256.Signing.PrivateKey().rawRepresentation.base64EncodedString())
    }

    func testInvitationRelayBecomesTheDefaultWhenThereIsNone() throws {
        let identity = RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage())
        let directory = try directory(identity: identity, debugEndpoint: false)
        let theirs = relay("B", name: "朋友的中继")
        let invitation = RemotePairingInvitation(macID: UUID(), macName: "朋友的 Mac", macKey: key(),
                                                 token: RemotePairingInvitation.newToken(), relay: theirs)
        _ = try directory.pair(with: invitation)
        XCTAssertEqual(directory.relayServerName(), "朋友的中继")
        XCTAssertNil(identity.peer(id: invitation.macID)?.relay, "默认就是它，不用单独记")
        XCTAssertEqual(identity.peer(id: invitation.macID)?.isMac, true)
    }

    func testInvitationRelayDoesNotReplaceMyOwnRelay() throws {
        let identity = RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage())
        let directory = try directory(identity: identity, debugEndpoint: false)
        directory.importRelayConfig(relay("A", name: "我的中继"))
        let theirs = relay("B", name: "朋友的中继")
        let invitation = RemotePairingInvitation(macID: UUID(), macName: "朋友的 Mac", macKey: key(),
                                                 token: RemotePairingInvitation.newToken(), relay: theirs)
        let mac = try XCTUnwrap(try directory.pair(with: invitation))
        XCTAssertEqual(directory.relayServerName(), "我的中继", "本机连的其他 Mac 还在自己的中继上")
        XCTAssertEqual(identity.peer(id: invitation.macID)?.relay, theirs)
        XCTAssertEqual(mac.relay, theirs, "连这台 Mac 走朋友的中继")
        XCTAssertEqual(directory.client(for: mac).pairingToken, invitation.token)
    }

    func testRelayConfigSentByAConnectedMacFollowsTheSameRule() throws {
        let identity = RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage())
        let directory = try directory(identity: identity, debugEndpoint: false)
        directory.importRelayConfig(relay("A", name: "我的中继"))
        let peer = RemotePeer(id: UUID(), name: "朋友的 Mac", publicKey: key(), pairedAt: .now)
        try identity.trust(peer)
        let theirs = relay("B", name: "朋友的中继")
        directory.receiveRelayConfig(theirs, from: peer.id)
        XCTAssertEqual(identity.peer(id: peer.id)?.relay, theirs)
        XCTAssertEqual(directory.relayServerName(), "我的中继")
    }
}
