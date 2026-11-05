import CryptoKit
import XCTest
@preconcurrency import Network
@testable import uTerm

/// 公网路径的门禁（`RemoteConnectionOrigin.internet`）：不经真实中继，用内存字节流直接接进真实的 `RemoteHostServer`。
@MainActor
final class RemoteInternetAccessTests: XCTestCase {

    /// 手机端的连接要活到用例结束：`RemoteLink` 释放后回调不再触发，就看不到 Mac 把它断开了。
    private var links: [RemoteLink] = []

    override func tearDown() async throws {
        links.forEach { $0.close() }
        links = []
        try await super.tearDown()
    }

    private final class Inbox: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [RemoteMessage] = []
        private var closedFlag = false
        func add(_ message: RemoteMessage) { lock.lock(); messages.append(message); lock.unlock() }
        func close() { lock.lock(); closedFlag = true; lock.unlock() }
        var all: [RemoteMessage] { lock.lock(); defer { lock.unlock() }; return messages }
        var closed: Bool { lock.lock(); defer { lock.unlock() }; return closedFlag }
        func of(_ kind: RemoteMessage.Kind) -> [RemoteMessage] { all.filter { $0.kind == kind } }
    }

    private struct Phone {
        let key = Curve25519.KeyAgreement.PrivateKey()
        let id = UUID()
        var peer: RemotePeer { RemotePeer(id: id, name: "手机", publicKey: key.publicKey.rawRepresentation, pairedAt: Date()) }
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return true
    }

    private func makeServer(allowed: Set<UUID> = [], roster: RemoteCloudRoster? = nil) -> RemoteHostServer {
        let server = RemoteHostServer(registry: TerminalSessionRegistry(),
                                      identity: RemoteIdentityStore(storage: RemoteMemoryStorage()), roster: roster,
                                      localName: "测试 Mac", localID: UUID(), advertises: false,
                                      keyConfirmationTimeout: .milliseconds(300))
        server.internetAccessPolicy = { allowed.contains($0) }
        return server
    }

    private func keys() -> (phone: RemoteHandshakeKeys, mac: RemoteHandshakeKeys) {
        let a = SymmetricKey(size: .bits256), b = SymmetricKey(size: .bits256)
        return (RemoteHandshakeKeys(send: a, receive: b), RemoteHandshakeKeys(send: b, receive: a))
    }

    /// 发起一条公网连接，走完握手。`confirm` = 握手后发不发 `keyConfirm`。
    private func connect(_ phone: Phone, to server: RemoteHostServer, expected: UUID? = nil, helloID: UUID? = nil,
                         features: [String]? = [RemoteFeature.keyConfirmation, RemoteFeature.heartbeat],
                         confirm: Bool = true) async -> (RemoteLink, Inbox) {
        let (phoneSide, macSide) = RemoteMemoryTransport.pair()
        let pair = keys()
        server.accept(transport: macSide, origin: .internet(peerID: expected ?? phone.id, keys: pair.mac, path: .relay))
        let inbox = Inbox()
        let link = RemoteLink(transport: phoneSide)
        links.append(link)
        link.setHandlers(onMessage: { inbox.add($0) }, onClose: { _ in inbox.close() })
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let hello = RemoteHello(version: RemoteConstants.protocolVersion, deviceID: helloID ?? phone.id, deviceName: "手机",
                                ephemeralKey: ephemeral.publicKey.rawRepresentation,
                                staticKey: phone.key.publicKey.rawRepresentation, features: features)
        do {
            _ = try await link.establish(role: .initiator, hello: hello, staticKey: phone.key, ephemeralKey: ephemeral,
                                         handshakeKeys: pair.phone)
            if confirm { link.send(RemoteMessage(.keyConfirm)) }
        } catch {
            // Mac 一看到握手内容就拒绝时，手机这边可能还没走完握手。用例看的是「被断开」。
            inbox.close()
        }
        return (link, inbox)
    }

    private func pairing(_ inbox: Inbox) -> [RemotePairingState] {
        inbox.of(.pairing).compactMap { $0.payload.first.flatMap(RemotePairingState.init(rawValue:)) }
    }

    func test_allowed_trusted_device_connects_without_any_prompt() async throws {
        let phone = Phone()
        let server = makeServer(allowed: [phone.id])
        try server.trust(phone.peer)
        let (link, inbox) = await connect(phone, to: server)
        let trusted = await waitUntil { self.pairing(inbox).contains(.trusted) }
        XCTAssertTrue(trusted)
        XCTAssertTrue(server.pairingRequests.isEmpty)
        XCTAssertEqual(server.connectedDevices, ["手机"])
        link.close()
    }

    func test_unknown_device_never_reaches_an_approval_prompt() async throws {
        let phone = Phone()
        let server = makeServer(allowed: [phone.id])
        let (_, inbox) = await connect(phone, to: server)
        let closed = await waitUntil { inbox.closed }
        XCTAssertTrue(closed, "不认识的设备要被断开")
        XCTAssertTrue(server.pairingRequests.isEmpty, "公网上不能弹审批框")
        XCTAssertTrue(server.identity.trustedPeers().isEmpty, "也不能写进信任")
    }

    func test_trusted_device_that_is_not_ticked_is_dropped() async throws {
        let phone = Phone()
        let server = makeServer(allowed: [])
        try server.trust(phone.peer)
        let (_, inbox) = await connect(phone, to: server)
        let closed = await waitUntil { inbox.closed }
        XCTAssertTrue(closed)
        XCTAssertFalse(pairing(inbox).contains(.trusted))
        XCTAssertTrue(server.connectedDevices.isEmpty)
    }

    /// 名册里的设备也要单独勾选：iCloud 账号失守不等于能静默控制这台 Mac。
    func test_roster_device_needs_the_tick_too() async throws {
        let phone = Phone()
        let roster = RemoteCloudRoster(storage: RemoteMemoryRosterStorage())
        roster.publish(RemoteRosterEntry(id: phone.id, name: "手机", publicKey: phone.peer.publicKey, platform: .mobile,
                                         updatedAt: Date()))
        let refused = makeServer(allowed: [], roster: roster)
        let (_, refusedInbox) = await connect(phone, to: refused)
        let closed = await waitUntil { refusedInbox.closed }
        XCTAssertTrue(closed)
        XCTAssertTrue(refused.identity.trustedPeers().isEmpty)

        let allowed = makeServer(allowed: [phone.id], roster: roster)
        let (link, inbox) = await connect(phone, to: allowed)
        let trusted = await waitUntil { self.pairing(inbox).contains(.trusted) }
        XCTAssertTrue(trusted)
        link.close()
    }

    func test_identity_different_from_the_signaled_device_is_dropped() async throws {
        let phone = Phone(), other = Phone()
        let server = makeServer(allowed: [phone.id, other.id])
        try server.trust(phone.peer)
        try server.trust(other.peer)
        let (_, inbox) = await connect(phone, to: server, expected: other.id)
        let closed = await waitUntil { inbox.closed }
        XCTAssertTrue(closed)
        XCTAssertTrue(server.connectedDevices.isEmpty)
    }

    func test_peer_without_key_confirmation_is_dropped_on_the_internet() async throws {
        let phone = Phone()
        let server = makeServer(allowed: [phone.id])
        try server.trust(phone.peer)
        let (_, inbox) = await connect(phone, to: server, features: nil, confirm: false)
        let closed = await waitUntil { inbox.closed }
        XCTAssertTrue(closed, "公网路径不接受老协议")
        XCTAssertTrue(server.connectedDevices.isEmpty)
    }

    func test_peer_that_never_confirms_is_dropped() async throws {
        let phone = Phone()
        let server = makeServer(allowed: [phone.id])
        try server.trust(phone.peer)
        let (_, inbox) = await connect(phone, to: server, confirm: false)
        let closed = await waitUntil { inbox.closed }
        XCTAssertTrue(closed)
        XCTAssertTrue(pairing(inbox).isEmpty)
    }

    func test_spoofer_with_a_known_public_key_is_dropped() async throws {
        let victim = Phone()
        let server = makeServer(allowed: [victim.id])
        try server.trust(victim.peer)
        let (phoneSide, macSide) = RemoteMemoryTransport.pair()
        let pair = keys()
        server.accept(transport: macSide, origin: .internet(peerID: victim.id, keys: pair.mac, path: .relay))
        let inbox = Inbox()
        let link = RemoteLink(transport: phoneSide)
        link.setHandlers(onMessage: { inbox.add($0) }, onClose: { _ in inbox.close() })
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let hello = RemoteHello(version: RemoteConstants.protocolVersion, deviceID: victim.id, deviceName: "冒充",
                                ephemeralKey: ephemeral.publicKey.rawRepresentation,
                                staticKey: victim.key.publicKey.rawRepresentation,
                                features: [RemoteFeature.keyConfirmation])
        let spoofer = Curve25519.KeyAgreement.PrivateKey()
        _ = try await link.establish(role: .initiator, hello: hello, staticKey: spoofer, ephemeralKey: ephemeral,
                                     handshakeKeys: pair.phone)
        link.send(RemoteMessage(.keyConfirm))
        let closed = await waitUntil { inbox.closed }
        XCTAssertTrue(closed)
        XCTAssertTrue(server.connectedDevices.isEmpty)
    }

    /// 中继看不到明文握手，没拿到握手密钥的人也进不来。
    func test_handshake_frames_are_sealed_and_wrong_keys_fail() async throws {
        let phone = Phone()
        let server = makeServer(allowed: [phone.id])
        try server.trust(phone.peer)
        let (phoneSide, macSide) = RemoteMemoryTransport.pair()
        server.accept(transport: macSide, origin: .internet(peerID: phone.id, keys: keys().mac, path: .relay))
        let link = RemoteLink(transport: phoneSide)
        link.setHandlers(onMessage: { _ in }, onClose: { _ in })
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let hello = RemoteHello(version: RemoteConstants.protocolVersion, deviceID: phone.id, deviceName: "手机",
                                ephemeralKey: ephemeral.publicKey.rawRepresentation,
                                staticKey: phone.key.publicKey.rawRepresentation,
                                features: [RemoteFeature.keyConfirmation])
        do {
            _ = try await link.establish(role: .initiator, hello: hello, staticKey: phone.key, ephemeralKey: ephemeral,
                                         handshakeKeys: keys().phone)
            XCTFail("握手密钥不对不该成功")
        } catch {}
        XCTAssertTrue(server.connectedDevices.isEmpty)
    }

    func test_unticking_a_device_cuts_its_internet_connection_but_not_local_ones() async throws {
        let phone = Phone()
        var allowed: Set<UUID> = [phone.id]
        let server = RemoteHostServer(registry: TerminalSessionRegistry(),
                                      identity: RemoteIdentityStore(storage: RemoteMemoryStorage()),
                                      localName: "测试 Mac", localID: UUID(), advertises: false)
        server.internetAccessPolicy = { allowed.contains($0) }
        try server.trust(phone.peer)

        let (_, internet) = await connect(phone, to: server)
        let connected = await waitUntil { self.pairing(internet).contains(.trusted) }
        XCTAssertTrue(connected)

        let (localSide, macSide) = RemoteMemoryTransport.pair()
        server.accept(transport: macSide)
        let localInbox = Inbox()
        let local = RemoteLink(transport: localSide)
        local.setHandlers(onMessage: { localInbox.add($0) }, onClose: { _ in localInbox.close() })
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        _ = try await local.establish(role: .initiator,
                                      hello: RemoteHello(version: RemoteConstants.protocolVersion, deviceID: phone.id, deviceName: "手机",
                                                         ephemeralKey: ephemeral.publicKey.rawRepresentation,
                                                         staticKey: phone.key.publicKey.rawRepresentation),
                                      staticKey: phone.key, ephemeralKey: ephemeral)

        allowed = []
        server.internetAccessChanged()
        let cut = await waitUntil { internet.closed }
        XCTAssertTrue(cut, "取消勾选后公网连接要立刻断")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(localInbox.closed, "局域网连接不受影响")
        local.close()
    }

    func test_unauthenticated_internet_connections_are_capped() async throws {
        let server = makeServer()
        var sides: [RemoteMemoryTransport] = []
        for _ in 0..<12 {
            let (phoneSide, macSide) = RemoteMemoryTransport.pair()
            sides.append(phoneSide)
            server.accept(transport: macSide, origin: .internet(peerID: UUID(), keys: keys().mac, path: .relay))
        }
        let closedInboxes = sides.map { side -> Inbox in
            let inbox = Inbox()
            side.start(queue: DispatchQueue(label: "test.side")) { _ in }
            side.receive(maximumLength: 1024) { _, isComplete, _ in if isComplete { inbox.close() } }
            return inbox
        }
        let refused = await waitUntil { closedInboxes.filter(\.closed).count == 4 }
        XCTAssertTrue(refused, "第 9 条起直接拒绝，实际 \(closedInboxes.filter(\.closed).count)")
    }

    func test_ticked_device_receives_the_relay_config_after_connecting() async throws {
        let phone = Phone()
        let server = makeServer(allowed: [phone.id])
        try server.trust(phone.peer)
        let config = RemoteRelayConfig(name: "家里", host: "relay.test", port: 47310, relayID: "abc",
                                       key: P256.Signing.PrivateKey().rawRepresentation.base64EncodedString())
        server.relayConfig = config
        let (link, inbox) = await connect(phone, to: server,
                                              features: [RemoteFeature.keyConfirmation, RemoteFeature.relayConfig])
        let delivered = await waitUntil { !inbox.of(.relayConfig).isEmpty }
        XCTAssertTrue(delivered)
        XCTAssertEqual(RemoteRelayConfig(importing: try XCTUnwrap(inbox.of(.relayConfig).first).payload), config)
        link.close()
    }

    func test_unticked_device_on_the_local_network_does_not_get_the_relay_config() async throws {
        let phone = Phone()
        let server = makeServer(allowed: [])
        try server.trust(phone.peer)
        server.relayConfig = RemoteRelayConfig(name: "家里", host: "relay.test", port: 47310, relayID: "abc",
                                               key: P256.Signing.PrivateKey().rawRepresentation.base64EncodedString())
        let (phoneSide, macSide) = RemoteMemoryTransport.pair()
        server.accept(transport: macSide)
        let inbox = Inbox()
        let link = RemoteLink(transport: phoneSide)
        link.setHandlers(onMessage: { inbox.add($0) }, onClose: { _ in inbox.close() })
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        _ = try await link.establish(role: .initiator,
                                     hello: RemoteHello(version: RemoteConstants.protocolVersion, deviceID: phone.id, deviceName: "手机",
                                                        ephemeralKey: ephemeral.publicKey.rawRepresentation,
                                                        staticKey: phone.key.publicKey.rawRepresentation,
                                                        features: [RemoteFeature.relayConfig]),
                                     staticKey: phone.key, ephemeralKey: ephemeral)
        let paired = await waitUntil { !self.pairing(inbox).isEmpty }
        XCTAssertTrue(paired)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(inbox.of(.relayConfig).isEmpty, "没勾选的设备拿不到成员密钥")
        link.close()
    }

    func test_internet_candidates_merge_trusted_and_roster_phones_only() throws {
        let phone = Phone(), rosterPhone = Phone(), rosterMac = Phone()
        let roster = RemoteCloudRoster(storage: RemoteMemoryRosterStorage())
        roster.publish(RemoteRosterEntry(id: rosterPhone.id, name: "B", publicKey: rosterPhone.peer.publicKey, platform: .mobile,
                                         updatedAt: Date()))
        roster.publish(RemoteRosterEntry(id: rosterMac.id, name: "Mac", publicKey: rosterMac.peer.publicKey, platform: .mac,
                                         updatedAt: Date()))
        let server = makeServer(roster: roster)
        try server.trust(phone.peer)
        XCTAssertEqual(Set(server.internetAccessCandidates.map(\.id)), [phone.id, rosterPhone.id])
    }

    func test_settings_default_to_closed_and_persist() {
        let suite = "remote.internet.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID()
        let settings = RemoteControlSettings(defaults: defaults)
        XCTAssertFalse(settings.isInternetEnabled)
        XCTAssertFalse(settings.allowsInternetAccess(id))
        settings.isEnabled = true
        settings.isInternetEnabled = true
        XCTAssertFalse(settings.allowsInternetAccess(id), "总开关开了设备也要单独勾选")
        settings.internetDevices.insert(id)
        XCTAssertTrue(settings.allowsInternetAccess(id))
        settings.isEnabled = false
        XCTAssertFalse(settings.allowsInternetAccess(id), "远控总开关关了就全关")

        let reloaded = RemoteControlSettings(defaults: defaults)
        XCTAssertTrue(reloaded.isInternetEnabled)
        XCTAssertEqual(reloaded.internetDevices, [id])
    }

    func test_internet_rate_control_starts_low_with_room_to_grow() {
        let lan = RemoteRateController(width: 2144, height: 1206, now: 0)
        let wan = RemoteRateController(width: 2144, height: 1206, path: .relay, now: 0)
        XCTAssertEqual(wan.bitrate, RemoteRateController.internetInitialBitrate)
        XCTAssertGreaterThan(lan.bitrate, wan.bitrate)
        XCTAssertEqual(wan.config.maxBitrate, lan.config.maxBitrate, "公网不设固定额度，上限一样")
        XCTAssertGreaterThan(wan.config.maxInflightFrames, lan.config.maxInflightFrames)
    }

    /// 往返 200 ms 时帧数上限不能把 60 fps 卡成 40 fps。
    func test_internet_inflight_limit_follows_round_trip() {
        var wan = RemoteRateController(width: 1280, height: 800, path: .relay, now: 0)
        wan.observe(latencyNanos: 200_000_000, now: 1_000)
        XCTAssertGreaterThanOrEqual(wan.inflightFrameLimit, 16)
        var lan = RemoteRateController(width: 1280, height: 800, now: 0)
        lan.observe(latencyNanos: 200_000_000, now: 1_000)
        XCTAssertEqual(lan.inflightFrameLimit, 8)
    }

    func test_round_trip_is_measured_from_ping_and_pong() async throws {
        let phone = Phone()
        let server = makeServer(allowed: [phone.id])
        try server.trust(phone.peer)
        let (link, inbox) = await connect(phone, to: server)
        let trusted = await waitUntil { self.pairing(inbox).contains(.trusted) }
        XCTAssertTrue(trusted)
        link.send(RemoteMessage(.ping))
        let ponged = await waitUntil { !inbox.of(.pong).isEmpty }
        XCTAssertTrue(ponged)
        let measured = await withCheckedContinuation { (continuation: CheckedContinuation<TimeInterval?, Never>) in
            link.queue.async { continuation.resume(returning: link.latestRoundTrip) }
        }
        XCTAssertNotNil(measured)
        link.close()
    }
}
