import CryptoKit
@preconcurrency import Network
import SwiftUI
import UIKit
import XCTest
@testable import uTermMobile

/// 「我的 Mac」只列配对过的 Mac（同一 Apple ID 的名册 + 本机信任的），按设备 ID 对号在线状态；
/// 局域网里别人的 Mac 不出现。新建终端抽屉只列其中在线的。
@MainActor
final class RemoteMacDirectoryTests: XCTestCase {
    private static let macName = "调试 Mac（127.0.0.1:1）"

    /// 带调试直连地址的目录（调试 Mac 事先不知道身份，总是列出、总是算在线）。
    private func directory(roster: RemoteCloudRoster? = nil,
                           identity: RemoteIdentityStore = RemoteIdentityStore(storage: RemoteMemoryStorage()),
                           debugEndpoint: Bool = true) throws -> RemoteMacDirectory {
        let suite = "RemoteMacDirectoryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        if debugEndpoint { defaults.set("127.0.0.1:1", forKey: "RemoteDebugEndpoint") }
        let directory = RemoteMacDirectory(identity: identity, roster: roster, defaults: defaults)
        directory.activate()
        return directory
    }

    private func key() -> Data { Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation }
    private let somewhere = NWEndpoint.hostPort(host: "192.168.1.9", port: 4000)

    func testListsRosterAndTrustedMacsAndMatchesOnlineByDeviceID() {
        let fromCloud = RemoteRosterEntry(id: UUID(), name: "MacBook Pro", publicKey: key(), platform: .mac,
                                          updatedAt: .now)
        let phone = RemoteRosterEntry(id: UUID(), name: "iPhone", publicKey: key(), platform: .mobile, updatedAt: .now)
        let scanned = RemotePeer(id: UUID(), name: "办公室 iMac", publicKey: key(), pairedAt: .now)
        let stranger = UUID()
        let online = RemoteMacDirectory.onlineMacs([
            ("我的 MacBook Pro", fromCloud.id.uuidString, somewhere),
            ("别人的 Mac", stranger.uuidString, somewhere),
            ("老版本 Mac", nil, somewhere),
        ])
        XCTAssertEqual(Set(online.keys), [fromCloud.id, stranger], "没有设备 ID 的结果不认")

        let macs = RemoteMacDirectory.knownMacs(trusted: [scanned], roster: [fromCloud, phone], blocked: { _ in false },
                                                online: online)

        XCTAssertEqual(macs.map(\.deviceID), [fromCloud.id, scanned.id], "只有配对过的 Mac，在线的在前；手机和别人的 Mac 都不在")
        XCTAssertEqual(macs[0].name, "我的 MacBook Pro", "在线时用 Bonjour 上的电脑名（改过名也跟得上）")
        XCTAssertEqual(macs[0].source, .iCloud)
        XCTAssertTrue(macs[0].isOnline)
        XCTAssertEqual(macs[1].source, .paired)
        XCTAssertFalse(macs[1].isOnline)
        XCTAssertEqual(macs[0].expectedPeer?.publicKey, fromCloud.publicKey, "连的时候按名册里的公钥核对")
    }

    func testSameNameDoesNotMakeAStrangerLookPaired() {
        let mine = RemotePeer(id: UUID(), name: "MacBook Pro", publicKey: key(), pairedAt: .now)
        let online = RemoteMacDirectory.onlineMacs([("MacBook Pro", UUID().uuidString, somewhere)])
        let macs = RemoteMacDirectory.knownMacs(trusted: [mine], roster: [], blocked: { _ in false }, online: online)
        XCTAssertEqual(macs.count, 1)
        XCTAssertFalse(macs[0].isOnline, "同名的另一台 Mac 不算我的这台在线")
    }

    /// Mac 重装后换了密钥：名册里是新的，本机信任里还是旧的。以名册为准，否则这台 Mac 永远连不上。
    func testRosterKeyWinsOverAStaleLocalKey() {
        let id = UUID()
        let stale = RemotePeer(id: id, name: "MacBook Pro", publicKey: key(), pairedAt: .now)
        let entry = RemoteRosterEntry(id: id, name: "MacBook Pro", publicKey: key(), platform: .mac, updatedAt: .now)
        let macs = RemoteMacDirectory.knownMacs(trusted: [stale], roster: [entry], blocked: { _ in false }, online: [:])
        XCTAssertEqual(macs.map(\.publicKey), [entry.publicKey])
        XCTAssertEqual(macs.first?.source, .iCloud)
    }

    func testBlockedRosterMacIsHidden() {
        let entry = RemoteRosterEntry(id: UUID(), name: "旧 Mac", publicKey: key(), platform: .mac, updatedAt: .now)
        let macs = RemoteMacDirectory.knownMacs(trusted: [], roster: [entry], blocked: { $0 == entry.id }, online: [:])
        XCTAssertTrue(macs.isEmpty, "忘记过的 Mac，名册里还有也不再出现")
    }

    func testScanningPairsAndForgettingBlocks() throws {
        let identity = RemoteIdentityStore(storage: RemoteMemoryStorage())
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

    func testRosterDrivenListUsesTheRoster() throws {
        let roster = RemoteCloudRoster(storage: RemoteMemoryRosterStorage())
        let entry = RemoteRosterEntry(id: UUID(), name: "MacBook Pro", publicKey: key(), platform: .mac, updatedAt: .now)
        roster.publish(entry)
        let directory = try directory(roster: roster, debugEndpoint: false)
        XCTAssertEqual(directory.macs.map(\.deviceID), [entry.id])
        XCTAssertTrue(directory.pairedMacs.isEmpty, "不在线的不进新建终端抽屉")
        XCTAssertEqual(roster.entries().filter { $0.platform == .mobile }.map(\.id), [RemoteLocalDevice.id()],
                       "启用后手机把自己登进名册，同一 Apple ID 的 Mac 才认得它")
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
}
