import CryptoKit
import XCTest
@preconcurrency import Network
@testable import uTerm

/// 经真实 `uterm-relay` 的端到端：手机 ↔ 中继 ↔ Mac，全部是真实代码，只有终端后端是假的。
///
/// 要有跑着的中继，由 `make test-relay-e2e` 起好后经环境变量 `TEST_RUNNER_UTERM_RELAY_CONFIG` 传进来；
/// 没有时跳过。
@MainActor
final class RemoteRelayEndToEndTests: XCTestCase {

    private func relayConfig() throws -> RemoteRelayConfig {
        guard let json = ProcessInfo.processInfo.environment["UTERM_RELAY_CONFIG"], !json.isEmpty else {
            throw XCTSkip("没有配置真实中继，用 make test-relay-e2e 跑")
        }
        return try XCTUnwrap(RemoteRelayConfig(importing: Data(json.utf8)))
    }

    /// 「测试连接」：TCP、成员认证、UDP 三项都通，并读到中继的构建版本；换一把成员密钥认证就不过。
    func testCheckPassesAgainstARealRelay() async throws {
        let config = try relayConfig()
        let result = await RemoteRelayCheck.run(config: config)
        XCTAssertEqual(result.tcp, .ok, result.problems.joined(separator: "\n"))
        XCTAssertEqual(result.auth, .ok, result.problems.joined(separator: "\n"))
        XCTAssertEqual(result.udp, .ok, result.problems.joined(separator: "\n"))
        XCTAssertNotNil(result.mappedAddress)
        XCTAssertNotNil(result.onlineHosts)
        if let built = ProcessInfo.processInfo.environment["UTERM_RELAY_VERSION"], !built.isEmpty {
            XCTAssertEqual(result.serverVersion, built, "hello 里的版本应是这次编出来的中继")
        }

        var stranger = config
        stranger.key = P256.Signing.PrivateKey().rawRepresentation.base64EncodedString()
        let refused = await RemoteRelayCheck.run(config: stranger)
        XCTAssertEqual(refused.tcp, .ok)
        XCTAssertEqual(refused.auth, .failed)
        XCTAssertNil(refused.serverVersion, "认证没过不该知道中继版本")
        XCTAssertFalse(refused.isUsable)
    }

    private func waitUntil(_ timeout: TimeInterval = 10, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    private struct Mac {
        let server: RemoteHostServer
        let session: TerminalSession
        let backend: MockBackend
        let sessionID: UUID
        let peer: RemotePeer
    }

    private final class Allowed: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: Set<UUID> = []
        func set(_ value: Set<UUID>) { lock.lock(); ids = value; lock.unlock() }
        func contains(_ id: UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return ids.contains(id) }
    }

    private func makeMac(config: RemoteRelayConfig, allowed: Allowed,
                         desktop: RemoteDesktopEnvironment = .disabled) async throws -> Mac {
        let registry = TerminalSessionRegistry()
        let session = TerminalSession()
        let backend = MockBackend()
        await session.connect(using: backend)
        let sessionID = UUID()
        registry.register(TerminalSessionEntry(id: sessionID, serverID: UUID(), serverName: "测试主机",
                                               windowKind: TerminalWindowKind.workspace, title: "zsh",
                                               connectedAt: Date()), session: session)
        let identity = RemoteIdentityStore(role: .controllers, storage: RemoteMemoryStorage())
        let suite = "RemoteRelayEndToEndTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let server = RemoteHostServer(registry: registry, identity: identity, localName: "测试 Mac", localID: UUID(),
                                      advertises: false, relayRevocations: RemoteRelayRevocations(defaults: defaults),
                                      desktopEnvironment: desktop)
        server.internetAccessPolicy = { allowed.contains($0) }
        server.relayConfig = config
        server.updateInternetAccess(enabled: true, keepAwake: false)
        let registered = await waitUntil { server.relayLink?.state == .registered }
        XCTAssertTrue(registered, "没注册上中继：\(String(describing: server.relayLink?.state))")
        let peer = RemotePeer(id: server.localID, name: "测试 Mac",
                              publicKey: try identity.localIdentity().publicKey.rawRepresentation, pairedAt: Date())
        return Mac(server: server, session: session, backend: backend, sessionID: sessionID, peer: peer)
    }

    private struct Phone {
        var identity = RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage())
        let id = RemoteLocalDevice.id()

        func peer() throws -> RemotePeer {
            RemotePeer(id: id, name: "测试 iPhone", publicKey: try identity.localIdentity().publicKey.rawRepresentation,
                       pairedAt: Date())
        }
    }

    private func makeClient(phone: Phone, mac: RemotePeer, relay: RemoteRelayClient,
                            allowsDirect: Bool = false) -> RemoteMacClient {
        let client = RemoteMacClient(macName: mac.name, endpoint: .hostPort(host: "127.0.0.1", port: 1),
                                     identity: phone.identity, expectedPeer: mac)
        let dialer = RemotePathDialer(relay: relay, identity: phone.identity, localID: phone.id, allowsDirect: allowsDirect)
        client.updateRoutes(endpoint: nil, internetDialer: { token in try await dialer.dial(mac, invitationToken: token) })
        return client
    }

    private final class Received: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        func add(_ data: Data) { lock.lock(); bytes.append(data); lock.unlock() }
        func contains(_ needle: Data) -> Bool { lock.lock(); defer { lock.unlock() }; return bytes.range(of: needle) != nil }
    }

    /// 不同 Apple ID、不在同一网络：凭带中继的邀请第一次经中继连过来就配上，并开通公网接入；之后不带凭据也能连。
    func test_invitation_pairs_a_stranger_through_the_relay() async throws {
        let config = try relayConfig()
        let allowed = Allowed()
        let phone = Phone()
        let mac = try await makeMac(config: config, allowed: allowed)
        defer { mac.server.stop(); mac.session.dispose() }
        mac.server.grantInternetAccess = { id in allowed.set([id]) }
        let invitation = try mac.server.makePairingInvitation()
        let shared = try XCTUnwrap(invitation.relay, "开着公网接入：邀请带上中继")
        XCTAssertEqual(shared.relayID, config.relayID)
        XCTAssertEqual(shared.scope, mac.peer.id.uuidString, "带的是只能连这台 Mac 的成员证书")
        XCTAssertNotEqual(shared.key, config.key, "中继本身的成员密钥不外发")
        XCTAssertEqual(TimeInterval(try XCTUnwrap(shared.expires)), Date().timeIntervalSince1970 + 86_400, accuracy: 5,
                       "邀请里的证书只给一天：没用掉的自己作废")
        let scanned = try XCTUnwrap(RemotePairingInvitation(scanned: invitation.url.absoluteString))
        XCTAssertEqual(scanned.relay, shared)
        let relay = RemoteRelayClient(config: try XCTUnwrap(scanned.relay))

        let first = makeClient(phone: phone, mac: mac.peer, relay: relay)
        first.pairingToken = scanned.token
        await first.connect()
        XCTAssertEqual(first.state, .connected)
        XCTAssertEqual(first.path, .relay)
        XCTAssertTrue(mac.server.pairingRequests.isEmpty)
        XCTAssertEqual(mac.server.trustedPeers.map(\.id), [phone.id])
        let grant = try XCTUnwrap(mac.server.trustedPeers.first?.relayGrant, "证书记到这台设备名下，忘记它时吊销")
        XCTAssertEqual(grant.key, shared.key)
        XCTAssertEqual(TimeInterval(try XCTUnwrap(grant.expires)),
                       Date().timeIntervalSince1970 + RemoteRelayConfig.certificateLifetime, accuracy: 5,
                       "配上后第一次连上来就续成 90 天，同一把钥匙")
        let renewedRelay = RemoteRelayClient(config: grant)
        let renewedSees = try await renewedRelay.onlineHosts()
        await renewedRelay.stop()
        XCTAssertEqual(renewedSees, [mac.peer.id], "续过的证书在真中继上照样能用")
        XCTAssertTrue(allowed.contains(phone.id))
        first.disconnect()

        let again = makeClient(phone: phone, mac: mac.peer, relay: relay)
        defer { again.disconnect() }
        await again.connect()
        XCTAssertEqual(again.state, .connected, "配上之后照常连")

        let stranger = Phone(identity: RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage()))
        let late = makeClient(phone: stranger, mac: mac.peer, relay: relay)
        late.pairingToken = scanned.token
        await late.connect()
        XCTAssertNotEqual(late.state, .connected, "用过的邀请别的设备用不了")
    }

    /// 成员证书只看得见、连得上发证的那台 Mac；不能拿去注册主机。
    func test_member_certificate_reaches_only_its_mac() async throws {
        let config = try relayConfig()
        let mine = try await makeMac(config: config, allowed: Allowed())
        defer { mine.server.stop(); mine.session.dispose() }
        let other = try await makeMac(config: config, allowed: Allowed())
        defer { other.server.stop(); other.session.dispose() }
        let certificate = try config.certificate(for: mine.peer.id)

        let relay = RemoteRelayClient(config: certificate)
        let seen = try await relay.onlineHosts()
        XCTAssertEqual(seen, [mine.peer.id], "只看得见发证的那台")
        let everything = try await RemoteRelayClient(config: config).onlineHosts()
        XCTAssertTrue(everything.isSuperset(of: [mine.peer.id, other.peer.id]))
        do {
            _ = try await relay.dial(host: other.peer.id, session: "s")
            XCTFail("证书不该连得上别的 Mac")
        } catch {
            XCTAssertEqual(error as? RemoteRelayError, .rejected)
        }

        let identity = RemoteIdentityStore(role: .controllers, storage: RemoteMemoryStorage())
        let host = RemoteHostServer(registry: TerminalSessionRegistry(), identity: identity, localName: "冒名",
                                    localID: UUID(), advertises: false)
        defer { host.stop() }
        host.relayConfig = certificate
        host.updateInternetAccess(enabled: true, keepAwake: false)
        let failed = await waitUntil(3) {
            if case .failed = host.relayLink?.state { return true }
            return false
        }
        XCTAssertTrue(failed, "证书不能注册主机：\(String(describing: host.relayLink?.state))")
    }

    /// 中继 1.3.0 只认有到期时间、且没过期的证书。
    func test_relay_refuses_certificates_without_a_valid_expiry() async throws {
        let config = try relayConfig()
        let mac = try await makeMac(config: config, allowed: Allowed())
        defer { mac.server.stop(); mac.session.dispose() }
        var legacy = try config.certificate(for: mac.peer.id)
        legacy.expires = nil
        await assertRejected(legacy)
        var stretched = try config.certificate(for: mac.peer.id)
        stretched.expires = (stretched.expires ?? 0) + 86_400
        await assertRejected(stretched)
        let tooLong = try config.certificate(for: mac.peer.id, lifetime: 200 * 86_400)
        await assertRejected(tooLong)
        let good = RemoteRelayClient(config: try config.certificate(for: mac.peer.id))
        let seen = try await good.onlineHosts()
        await good.stop()
        XCTAssertEqual(seen, [mac.peer.id])
    }

    /// 忘记设备、或邀请没用掉就作废：发出去的证书在中继上吊销，之后连不上。
    func test_forgetting_a_device_revokes_its_certificate() async throws {
        let config = try relayConfig()
        let allowed = Allowed()
        let phone = Phone()
        let mac = try await makeMac(config: config, allowed: allowed)
        defer { mac.server.stop(); mac.session.dispose() }
        mac.server.grantInternetAccess = { id in allowed.set([id]) }

        let unused = try XCTUnwrap(try mac.server.makePairingInvitation().relay)
        let used = try XCTUnwrap(try mac.server.makePairingInvitation().relay)
        XCTAssertNotEqual(unused.key, used.key, "每张邀请一张新证书")
        let confirmedUnused = await waitUntil { mac.server.relayRevocations.pending(relayID: config.relayID).isEmpty }
        XCTAssertTrue(confirmedUnused, "换了邀请：旧邀请里的证书吊销并经中继确认")
        await assertRejected(unused)

        let invitation = try XCTUnwrap(mac.server.pairingInvitation)
        let client = makeClient(phone: phone, mac: mac.peer, relay: RemoteRelayClient(config: used))
        client.pairingToken = invitation.token
        await client.connect()
        XCTAssertEqual(client.state, .connected)
        let usedRelay = RemoteRelayClient(config: used)
        let stillUsable = try await usedRelay.onlineHosts()
        await usedRelay.stop()
        XCTAssertEqual(stillUsable, [mac.peer.id], "用掉的邀请里的证书留给那台设备")

        mac.server.revoke(phone.id)
        let confirmed = await waitUntil { mac.server.relayRevocations.pending(relayID: config.relayID).isEmpty }
        XCTAssertTrue(confirmed, "忘记设备：它的证书在中继上吊销并经确认")
        await assertRejected(used)
        client.disconnect()
    }

    private func assertRejected(_ config: RemoteRelayConfig, file: StaticString = #filePath, line: UInt = #line) async {
        let relay = RemoteRelayClient(config: config)
        do {
            _ = try await relay.onlineHosts()
            XCTFail("吊销的证书还能用", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? RemoteRelayError, .rejected, file: file, line: line)
        }
        await relay.stop()
    }

    func test_phone_controls_a_terminal_through_the_relay() async throws {
        let config = try relayConfig()
        let allowed = Allowed()
        let phone = Phone()
        allowed.set([phone.id])
        let mac = try await makeMac(config: config, allowed: allowed)
        defer { mac.server.stop(); mac.session.dispose() }
        try mac.server.trust(try phone.peer())
        let relay = RemoteRelayClient(config: config)
        let client = makeClient(phone: phone, mac: mac.peer, relay: relay)
        defer { client.disconnect() }

        let online = try await relay.onlineHosts()
        XCTAssertTrue(online.contains(mac.peer.id), "中继上应该能看到这台 Mac")

        await client.connect()
        XCTAssertEqual(client.state, .connected)
        XCTAssertEqual(client.path, .relay)
        XCTAssertEqual(mac.server.connectedDevices.count, 1)

        let received = Received()
        let attachment = try await client.attach(sessionID: mac.sessionID,
                                                 size: try RemoteGridSize(decoding: Data([0, 80, 0, 24])),
                                                 sink: RemoteChannelSink(onOutput: { received.add($0) }, onClosed: { _, _ in }))
        let key = Data("ls -la\r".utf8)
        attachment.link.send(RemoteMessage(.input, channel: attachment.channel, payload: key))
        let wrote = await waitUntil { await mac.backend.writtenData.contains(key) }
        XCTAssertTrue(wrote, "按键经中继到 Mac")
        let marker = Data("来自 Mac 的输出".utf8)
        await mac.backend.emitOutput(marker)
        let echoed = await waitUntil { received.contains(marker) }
        XCTAssertTrue(echoed, "输出经中继到手机")

        let big = Data(repeating: 0x61, count: 2_000_000) + Data("<end>".utf8)
        await mac.backend.emitOutput(big)
        let finished = await waitUntil(20) { received.contains(Data("<end>".utf8)) }
        XCTAssertTrue(finished, "大块输出也要完整通过")
        XCTAssertEqual(client.state, .connected)
    }

    /// 声音经真实中继（调研 §16）：桌面视频拉满的同时开声音，走 TCP 中继 + `link-flow`，按 10 ms 拉取播放不断音。
    func test_desktop_audio_plays_through_the_relay_while_video_runs() async throws {
        let config = try relayConfig()
        let allowed = Allowed()
        let phone = Phone()
        allowed.set([phone.id])
        let fake = FakeDesktopMac()
        fake.detail = true
        let mac = try await makeMac(config: config, allowed: allowed, desktop: fake.environment())
        defer { mac.server.stop(); mac.session.dispose() }
        try mac.server.trust(try phone.peer())
        let client = makeClient(phone: phone, mac: mac.peer, relay: RemoteRelayClient(config: config))
        defer { client.disconnect() }
        await client.connect()
        XCTAssertEqual(client.path, .relay)
        let output = SilentAudioOutput()
        let session = RemoteDesktopSession(client: client, maxWidth: 1206, maxHeight: 2622, audioOutput: output)
        defer { session.stop() }
        await session.start()
        XCTAssertEqual(session.state, .streaming)
        session.setAudio(true)
        let playing = await waitUntil { session.audioState == .playing }
        XCTAssertTrue(playing, "\(session.audioState)")
        XCTAssertTrue(client.usesLinkFlow, "经中继也要启用链路排队")
        let source = try XCTUnwrap(fake.latestSource)
        source.prepareCycle(count: 12)
        source.run(fps: 30)
        let pull = try XCTUnwrap(output.pull)
        let player = Task.detached {
            while !Task.isCancelled {
                _ = pull(480)
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        try await Task.sleep(for: .seconds(8))
        player.cancel()
        source.pause()
        let audio = session.audioReceiver.snapshot()
        print("[中继探针·声音] 放出 \(audio.counters.played)，收到 \(audio.received)，补静音 \(audio.counters.concealed)，"
              + "欠载 \(audio.counters.underruns)，丢包追上 \(audio.counters.dropped)，目标深度 \(audio.targetMillis) ms，"
              + "视频 \(session.stats.framesPerSecond) fps \(String(format: "%.1f", session.stats.megabitsPerSecond)) Mbps")
        XCTAssertGreaterThan(audio.counters.played, 300, "8 s 应放出约 400 包")
        XCTAssertEqual(audio.counters.concealed, 0, "TCP 不丢包，不该有洞")
        XCTAssertLessThanOrEqual(audio.counters.underruns, 1)
        XCTAssertEqual(client.state, .connected)
    }

    func test_not_ticked_device_is_told_and_can_retry_after_being_ticked() async throws {
        let config = try relayConfig()
        let allowed = Allowed()
        let phone = Phone()
        let mac = try await makeMac(config: config, allowed: allowed)
        defer { mac.server.stop(); mac.session.dispose() }
        try mac.server.trust(try phone.peer())
        let client = makeClient(phone: phone, mac: mac.peer, relay: RemoteRelayClient(config: config))
        defer { client.disconnect() }

        await client.connect()
        guard case .failed(let message) = client.state else { return XCTFail("应该失败：\(client.state)") }
        XCTAssertEqual(message, RemoteRelayError.notAllowed.localizedDescription)
        XCTAssertFalse(client.pairingRefused, "这不是永久拒绝：勾选后还要能连")

        allowed.set([phone.id])
        await client.connect()
        XCTAssertEqual(client.state, .connected)
    }

    func test_stranger_gets_no_answer_and_sees_no_prompt() async throws {
        let config = try relayConfig()
        let allowed = Allowed()
        let mac = try await makeMac(config: config, allowed: allowed)
        defer { mac.server.stop(); mac.session.dispose() }
        let stranger = Phone()
        allowed.set([stranger.id])
        let client = makeClient(phone: stranger, mac: mac.peer, relay: RemoteRelayClient(config: config))
        defer { client.disconnect() }

        await client.connect()
        guard case .failed = client.state else { return XCTFail("应该失败：\(client.state)") }
        XCTAssertTrue(mac.server.pairingRequests.isEmpty)
        XCTAssertTrue(mac.server.connectedDevices.isEmpty)
    }

    func test_offline_mac_is_reported() async throws {
        let config = try relayConfig()
        let phone = Phone()
        let macKey = Curve25519.KeyAgreement.PrivateKey()
        let offline = RemotePeer(id: UUID(), name: "没开机的 Mac", publicKey: macKey.publicKey.rawRepresentation, pairedAt: Date())
        let client = makeClient(phone: phone, mac: offline, relay: RemoteRelayClient(config: config))
        await client.connect()
        guard case .failed(let message) = client.state else { return XCTFail("应该失败：\(client.state)") }
        XCTAssertEqual(message, RemoteRelayError.macOffline.localizedDescription)
    }

    func test_stopping_internet_access_leaves_the_relay() async throws {
        let config = try relayConfig()
        let mac = try await makeMac(config: config, allowed: Allowed())
        defer { mac.server.stop(); mac.session.dispose() }
        let relay = RemoteRelayClient(config: config)
        let before = try await relay.onlineHosts()
        XCTAssertTrue(before.contains(mac.peer.id))
        mac.server.updateInternetAccess(enabled: false, keepAwake: false)
        let gone = await waitUntil {
            let hosts = (try? await relay.onlineHosts()) ?? []
            return !hosts.contains(mac.peer.id)
        }
        XCTAssertTrue(gone, "关掉后应该从中继上消失")
    }

    func test_config_with_the_wrong_member_key_is_refused() async throws {
        var config = try relayConfig()
        config.key = P256.Signing.PrivateKey().rawRepresentation.base64EncodedString()
        let relay = RemoteRelayClient(config: config)
        do {
            _ = try await relay.onlineHosts()
            XCTFail("错误的成员密钥不该通过")
        } catch {
            XCTAssertEqual(error as? RemoteRelayError, .rejected, "中继对认证没过的请求一言不发直接断开")
        }
    }

    /// 真实的完整路径：中继上交换信令，真实 libjuice 打洞，KCP 上跑终端。
    func test_phone_goes_direct_when_hole_punching_works() async throws {
        let config = try relayConfig()
        let allowed = Allowed()
        let phone = Phone()
        allowed.set([phone.id])
        let mac = try await makeMac(config: config, allowed: allowed)
        defer { mac.server.stop(); mac.session.dispose() }
        try mac.server.trust(try phone.peer())
        let client = makeClient(phone: phone, mac: mac.peer, relay: RemoteRelayClient(config: config), allowsDirect: true)
        defer { client.disconnect() }
        let started = Date()
        await client.connect()
        print(String(format: "[直连探针·真实 ICE] 拨号到连上 %.0f ms", Date().timeIntervalSince(started) * 1000))
        XCTAssertEqual(client.state, .connected)
        XCTAssertEqual(client.path, .direct)

        let received = Received()
        let attachment = try await client.attach(sessionID: mac.sessionID,
                                                 size: try RemoteGridSize(decoding: Data([0, 80, 0, 24])),
                                                 sink: RemoteChannelSink(onOutput: { received.add($0) }, onClosed: { _, _ in }))
        let key = Data("ls -la\r".utf8)
        attachment.link.send(RemoteMessage(.input, channel: attachment.channel, payload: key))
        let wrote = await waitUntil { await mac.backend.writtenData.contains(key) }
        XCTAssertTrue(wrote, "按键经直连到 Mac")
        let big = Data(repeating: 0x61, count: 2_000_000) + Data("<end>".utf8)
        await mac.backend.emitOutput(big)
        let finished = await waitUntil(20) { received.contains(Data("<end>".utf8)) }
        XCTAssertTrue(finished, "大块输出也要完整通过")
        XCTAssertEqual(client.state, .connected)
        XCTAssertEqual(client.path, .direct)
    }

    /// 对端还不会打洞（旧版本）：回复里没有地址，手机直接走中继。
    func test_falls_back_to_the_relay_when_the_mac_offers_no_direct_path() async throws {
        let config = try relayConfig()
        let allowed = Allowed()
        let phone = Phone()
        allowed.set([phone.id])
        let mac = try await makeMac(config: config, allowed: allowed)
        defer { mac.server.stop(); mac.session.dispose() }
        try mac.server.trust(try phone.peer())
        mac.server.relayLink?.acceptsDirect = false
        let client = makeClient(phone: phone, mac: mac.peer, relay: RemoteRelayClient(config: config), allowsDirect: true)
        defer { client.disconnect() }
        await client.connect()
        XCTAssertEqual(client.state, .connected)
        XCTAssertEqual(client.path, .relay)
    }

    /// 打洞诊断走完整流程：真实中继的 STUN 和信令，真实 libjuice。
    func test_ice_probe_exchanges_candidates_through_the_relay() async throws {
        let config = try relayConfig()
        let allowed = Allowed()
        let phone = Phone()
        allowed.set([phone.id])
        let mac = try await makeMac(config: config, allowed: allowed)
        defer { mac.server.stop(); mac.session.dispose() }
        try mac.server.trust(try phone.peer())
        let runner = RemoteICEProbeRunner(relay: RemoteRelayClient(config: config), identity: phone.identity,
                                          localID: phone.id)
        // 两端都在这台机器上，只有私有与回环地址可配：关掉「只要公网」，这里验的是经中继交换地址的流程。
        let result = await runner.run(mac: mac.peer, publicOnly: false)
        print("[打洞探针·中继] \(result.summaryLine)")
        XCTAssertNil(result.failure)
        XCTAssertTrue(result.connected)
        XCTAssertEqual(result.lossPercent, 0)
        XCTAssertFalse(result.remoteCandidates.isEmpty)
    }

    /// 中继诊断走完整流程：真实中继的信令与回拨，Mac 把字节原样弹回，不接进远控。
    func test_relay_probe_echoes_through_the_relay() async throws {
        let config = try relayConfig()
        let allowed = Allowed()
        let phone = Phone()
        allowed.set([phone.id])
        let mac = try await makeMac(config: config, allowed: allowed)
        defer { mac.server.stop(); mac.session.dispose() }
        try mac.server.trust(try phone.peer())
        let probe = RemoteRelayProbe(relay: RemoteRelayClient(config: config), identity: phone.identity,
                                     localID: phone.id)
        let result = await probe.run(mac: mac.peer, pings: 20)
        print("[链路矩阵·中继] \(result.summaryLine)")
        XCTAssertNil(result.failure)
        XCTAssertTrue(result.connected)
        XCTAssertEqual(result.lossPercent, 0)
        XCTAssertNotNil(result.roundTripP95Millis)
    }

    /// 整个矩阵：每条路每轮一条结果，按顺序回报。
    func test_path_matrix_reports_every_mode_every_round() async throws {
        let config = try relayConfig()
        let allowed = Allowed()
        let phone = Phone()
        allowed.set([phone.id])
        let mac = try await makeMac(config: config, allowed: allowed)
        defer { mac.server.stop(); mac.session.dispose() }
        try mac.server.trust(try phone.peer())
        var runner = RemotePathMatrixRunner(identity: phone.identity, localID: phone.id)
        runner.relay = RemoteRelayClient(config: config)
        // 局域网那条路：本机起监听，经回环连（和 Bonjour 解析出的端点同一套连接代码）。
        mac.server.start()
        let listening = await waitUntil { mac.server.port != nil }
        XCTAssertTrue(listening)
        let port = try XCTUnwrap(mac.server.port.flatMap { NWEndpoint.Port(rawValue: $0) })
        runner.lan = RemoteLANTarget(macName: "测试 Mac", endpoint: .hostPort(host: "127.0.0.1", port: port),
                                     expectedPeer: mac.peer)
        let reported = Reported()
        let results = await runner.run(mac: mac.peer, rounds: 2) { await reported.add($0) }
        for summary in RemotePathProbeSummary.summarize(results) { print("[链路矩阵·本机] \(summary.line)") }
        let modes: [RemotePathProbeMode] = [.localNetwork, .directIPv6, .directIPv4, .relay]
        XCTAssertEqual(results.map(\.mode), modes + modes)
        XCTAssertEqual(results.map(\.round), [1, 1, 1, 1, 2, 2, 2, 2])
        let count = await reported.count
        XCTAssertEqual(count, 8)
        let lan = results.filter { $0.mode == .localNetwork }
        XCTAssertTrue(lan.allSatisfy(\.connected), "局域网这条路在本机必须通：\(lan.map(\.summaryLine))")
        XCTAssertTrue(lan.allSatisfy { $0.lossPercent == 0 && $0.roundTripMillis != nil })
        let chosen = RemotePathVerdict.chosen(RemotePathProbeSummary.summarize(results))
        XCTAssertEqual(chosen?.mode, .localNetwork, "局域网通时实际连接走局域网")
        // 只走公网时跳过局域网。打洞能不能通看本机网络（有公网 IPv6 时 IPv6 直连在本机就能打通），
        // 所以按这一次实测：哪条直连通过就该选它，都没通才落到中继。
        let internet = RemotePathVerdict.chosen(RemotePathProbeSummary.summarize(results), skipsLocalNetwork: true)?.mode
        let punched = [RemotePathProbeMode.directIPv6, .directIPv4].filter { mode in
            results.contains { $0.mode == mode && $0.connected }
        }
        print("[链路矩阵·本机] 打洞通过：\(punched)，只走公网时选：\(String(describing: internet))")
        if punched.isEmpty {
            XCTAssertEqual(internet, .relay, "只走公网、打洞都没通：落到中继")
        } else {
            XCTAssertTrue(internet.map { punched.contains($0) } ?? false,
                          "只走公网、打洞通了：选打通的那条直连，实际选 \(String(describing: internet))")
        }
        XCTAssertTrue(results.filter { $0.mode == .relay }.allSatisfy(\.connected), "中继这条路在本机必须通")
    }

    private actor Reported {
        var count = 0
        func add(_ result: RemotePathProbeResult) { count += 1 }
    }

    func test_ice_probe_is_denied_for_an_unticked_device() async throws {
        let config = try relayConfig()
        let phone = Phone()
        let mac = try await makeMac(config: config, allowed: Allowed())
        defer { mac.server.stop(); mac.session.dispose() }
        try mac.server.trust(try phone.peer())
        let runner = RemoteICEProbeRunner(relay: RemoteRelayClient(config: config), identity: phone.identity,
                                          localID: phone.id)
        let result = await runner.run(mac: mac.peer, publicOnly: false)
        XCTAssertFalse(result.connected)
        XCTAssertEqual(result.failure, RemoteRelayError.notAllowed.localizedDescription)
        XCTAssertTrue(result.remoteCandidates.isEmpty, "没勾选的设备拿不到 Mac 的地址")
    }

    func test_reconnects_to_the_relay_after_its_connection_drops() async throws {
        let config = try relayConfig()
        let mac = try await makeMac(config: config, allowed: Allowed())
        defer { mac.server.stop(); mac.session.dispose() }
        let link = try XCTUnwrap(mac.server.relayLink)
        link.dropConnectionForTesting()
        let reconnected = await waitUntil(8) { link.state == .registered }
        XCTAssertTrue(reconnected, "掉线后要自动重新注册，当前 \(link.state)")
    }
}
