import AgentKit
import SwiftData
import UIKit
import XCTest
@testable import uTermMobile

/// 局域网同步端到端：同一进程里起一个发送端（Mac 那一侧的角色）和一个接收端，
/// 走真实的 Bonjour 发现、明文握手、加密 offer、用户确认、分片传输、摘要校验与合并。
///
/// 钉的是接收侧这一轮的改动：解密 / 解码 / 拼装移出主线程、合并改在后台 `ModelContext`
/// 上做、合并时清掉同主键的重复记录。两端各用独立的内存容器与独立的 `UserDefaults`
/// 域，不碰宿主的数据、偏好与钥匙串里已有的条目（夹具里的 id 都是新造的）。
@MainActor
final class MobileLANSyncEndToEndTests: XCTestCase {

    func testFullSyncReachesReceiverAndCleansDuplicates() async throws {
        let senderContainer = try MobileFixtures.modelContainer(seed: .realistic)
        let receiverContainer = try MobileFixtures.emptyContainer()

        let senderProfiles = try senderContainer.mainContext.fetch(FetchDescriptor<ServerProfile>())
        let senderIDs = Set(senderProfiles.map(\.id))
        XCTAssertFalse(senderIDs.isEmpty)

        // 接收端预置：一条发送端没有的主机（应被删除）+ 同一主键的两份副本（应合成一份）。
        let rctx = receiverContainer.mainContext
        let stale = ServerProfile()
        stale.name = "only-on-receiver"
        rctx.insert(stale)
        let duplicatedID = try XCTUnwrap(senderIDs.first)
        for _ in 0..<2 {
            let copy = ServerProfile()
            copy.id = duplicatedID
            copy.name = "duplicate"
            rctx.insert(copy)
        }
        try rctx.save()

        let suffix = UUID().uuidString
        let senderDefaults = try XCTUnwrap(UserDefaults(suiteName: "lan-e2e-sender-\(suffix)"))
        let receiverDefaults = try XCTUnwrap(UserDefaults(suiteName: "lan-e2e-receiver-\(suffix)"))
        let sender = LANSyncCoordinator(
            role: .sender, preferences: SharedPreferencesSync(defaults: senderDefaults),
            dataStore: LANSyncDataStore(container: senderContainer), defaults: senderDefaults)
        let receiver = LANSyncCoordinator(
            role: .receiver, preferences: SharedPreferencesSync(defaults: receiverDefaults),
            dataStore: LANSyncDataStore(container: receiverContainer), defaults: receiverDefaults)
        defer {
            sender.stop()
            receiver.stop()
            senderDefaults.removePersistentDomain(forName: "lan-e2e-sender-\(suffix)")
            receiverDefaults.removePersistentDomain(forName: "lan-e2e-receiver-\(suffix)")
        }

        receiver.setPairingCode(sender.pairingCode)
        receiver.start()
        sender.start()

        // 接收端的 Bonjour 服务名就是本机设备名；局域网上别的设备也可能在广播，按名字挑。
        let deviceName = UIDevice.current.name
        let found = await waitUntil(timeout: 20) { sender.peers.contains { $0.name == deviceName } }
        XCTAssertTrue(found, "发送端没发现接收端：peers=\(sender.peers.map(\.name)) status=\(sender.status)")
        let peer = try XCTUnwrap(sender.peers.first { $0.name == deviceName })

        sender.sendSync(to: peer)
        let offered = await waitUntil(timeout: 20) { receiver.pendingOffer != nil }
        XCTAssertTrue(offered, "接收端没收到同步请求：sender=\(sender.status) receiver=\(receiver.status)")
        XCTAssertEqual(receiver.status, .waitingForConfirmation)

        receiver.confirmPendingSync()
        let done = await waitUntil(timeout: 40) {
            receiver.lastSyncedAt != nil && sender.status == .ready
        }
        XCTAssertTrue(done, "同步没有完成：sender=\(sender.status) receiver=\(receiver.status)")
        XCTAssertEqual(receiver.status, .hosting)

        // 合并在后台上下文里落盘；用新上下文读，确认真的进了库。
        let check = ModelContext(receiverContainer)
        let received = try check.fetch(FetchDescriptor<ServerProfile>())
        XCTAssertEqual(Set(received.map(\.id)), senderIDs, "主机集合与发送端不一致")
        XCTAssertEqual(received.count, senderIDs.count, "同主键的重复记录没有被清掉")
        XCTAssertFalse(received.contains { $0.name == "only-on-receiver" }, "发送端没有的记录没被删除")
        let names = Dictionary(uniqueKeysWithValues: senderProfiles.map { ($0.id, $0.name) })
        for profile in received {
            XCTAssertEqual(profile.name, names[profile.id], "字段没有按发送端覆盖")
        }
        // 主上下文（`@Query` 读的那个）也看得到后台合并的结果。
        let viaMain = try rctx.fetch(FetchDescriptor<ServerProfile>())
        XCTAssertEqual(Set(viaMain.filter { !$0.isDeleted }.map(\.id)), senderIDs)

        for type in ["QuickCommand", "ChatSession"] {
            let sent = try count(type, in: senderContainer.mainContext)
            let got = try count(type, in: check)
            XCTAssertEqual(got, sent, "\(type) 条数不一致")
        }
    }

    private func count(_ type: String, in context: ModelContext) throws -> Int {
        switch type {
        case "QuickCommand": return try context.fetchCount(FetchDescriptor<QuickCommand>())
        default: return try context.fetchCount(FetchDescriptor<ChatSession>())
        }
    }

    private func waitUntil(timeout seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }
}
