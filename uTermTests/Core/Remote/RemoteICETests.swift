import CryptoKit
import XCTest
@testable import uTerm

/// 打洞诊断：信令门禁、候选地址解析、记录，以及真实 libjuice 在本机打通。
final class RemoteICETests: XCTestCase {

    private struct Device {
        let key = Curve25519.KeyAgreement.PrivateKey()
        let id = UUID()
        var peer: RemotePeer { RemotePeer(id: id, name: "设备", publicKey: key.publicKey.rawRepresentation, pairedAt: Date()) }
    }

    private let sampleDescription = "a=ice-ufrag:abcd\r\na=ice-pwd:efgh\r\na=candidate:1 1 UDP 2122317823 192.168.1.2 49160 typ host\r\n"

    private func responder(mac: Device, phone: Device?, allowed: Bool) -> RemoteSignalResponder {
        let known = phone?.peer
        return RemoteSignalResponder(localKey: mac.key, localID: mac.id,
                                     recognize: { $0 == known?.id ? known : nil }, isAllowed: { _ in allowed })
    }

    private func sealedProbe(from phone: Device, to mac: Device, session: String, kind: RemoteSignalBody.Kind = .iceProbe,
                             at now: TimeInterval) throws -> String {
        let shared = try RemoteSignalBox.sharedKey(local: phone.key, remotePublicKey: mac.peer.publicKey)
        let body = RemoteSignalBody(kind: kind, deviceID: phone.id, sentAt: now, nonce: RemoteSignalBody.newNonce(),
                                    ice: sampleDescription)
        return try RemoteSignalBox.seal(body, key: shared, session: session, direction: .phoneToMac)
    }

    // MARK: - 门禁

    func test_allowed_device_gets_its_description_through() throws {
        let mac = Device(), phone = Device()
        var gate = responder(mac: mac, phone: phone, allowed: true)
        let box = try sealedProbe(from: phone, to: mac, session: "s", at: 100)
        guard case .accepted(let request) = gate.receiveProbe(session: "s", from: phone.id.uuidString, box: box, now: 100) else {
            return XCTFail("应该接受")
        }
        XCTAssertEqual(request.remoteDescription, sampleDescription)
        XCTAssertEqual(request.peer.id, phone.id)
    }

    /// 候选地址里有 Mac 的公网 IP：没勾选的设备只得到一句拒绝。
    func test_unticked_device_gets_a_denial_without_any_address() throws {
        let mac = Device(), phone = Device()
        var gate = responder(mac: mac, phone: phone, allowed: false)
        let box = try sealedProbe(from: phone, to: mac, session: "s", at: 100)
        guard case .denied(let sealed) = gate.receiveProbe(session: "s", from: phone.id.uuidString, box: box, now: 100) else {
            return XCTFail("应该拒绝")
        }
        let shared = try RemoteSignalBox.sharedKey(local: phone.key, remotePublicKey: mac.peer.publicKey)
        let reply = try RemoteSignalBox.open(sealed, key: shared, session: "s", direction: .macToPhone)
        XCTAssertEqual(reply.kind, .denied)
        XCTAssertNil(reply.ice)
    }

    func test_stranger_replay_and_wrong_kind_get_nothing() throws {
        let mac = Device(), phone = Device(), stranger = Device()
        var gate = responder(mac: mac, phone: phone, allowed: true)
        func isIgnored(_ decision: RemoteSignalResponder.ProbeDecision) -> Bool {
            if case .ignore = decision { return true }
            return false
        }
        let strangerBox = try sealedProbe(from: stranger, to: mac, session: "a", at: 100)
        XCTAssertTrue(isIgnored(gate.receiveProbe(session: "a", from: stranger.id.uuidString, box: strangerBox, now: 100)))

        let box = try sealedProbe(from: phone, to: mac, session: "b", at: 100)
        XCTAssertFalse(isIgnored(gate.receiveProbe(session: "b", from: phone.id.uuidString, box: box, now: 100)))
        XCTAssertTrue(isIgnored(gate.receiveProbe(session: "b", from: phone.id.uuidString, box: box, now: 101)), "重放")

        let stale = try sealedProbe(from: phone, to: mac, session: "c", at: 100)
        XCTAssertTrue(isIgnored(gate.receiveProbe(session: "c", from: phone.id.uuidString, box: stale, now: 100 + 1000)), "过期")

        let offer = try sealedProbe(from: phone, to: mac, session: "d", kind: .offer, at: 100)
        XCTAssertTrue(isIgnored(gate.receiveProbe(session: "d", from: phone.id.uuidString, box: offer, now: 100)))
    }

    /// 诊断不能冒充正式连接，否则诊断的信令会被拿来开一条中继。
    func test_probe_does_not_create_a_pending_connection() throws {
        let mac = Device(), phone = Device()
        var gate = responder(mac: mac, phone: phone, allowed: true)
        let box = try sealedProbe(from: phone, to: mac, session: "s", at: 100)
        XCTAssertNil(gate.respond(session: "s", from: phone.id.uuidString, box: box, now: 100))
        _ = gate.receiveProbe(session: "s", from: phone.id.uuidString, box: box, now: 100)
        XCTAssertNil(gate.claim(session: "s", now: 100))
    }

    // MARK: - 中继诊断

    /// 中继诊断：登记会话、回一个可以拨的答复；回拨来时只能认领一次，也不会被当成正式连接接进来。
    func test_relay_probe_registers_a_one_time_echo_session() throws {
        let mac = Device(), phone = Device()
        var gate = responder(mac: mac, phone: phone, allowed: true)
        let box = try sealedProbe(from: phone, to: mac, session: "r", kind: .relayProbe, at: 100)
        guard case .relayEcho(let sealed) = gate.receiveProbe(session: "r", from: phone.id.uuidString, box: box, now: 100) else {
            return XCTFail("勾选过的设备应该拿到中继诊断的答复")
        }
        let shared = try RemoteSignalBox.sharedKey(local: phone.key, remotePublicKey: mac.peer.publicKey)
        let reply = try RemoteSignalBox.open(sealed, key: shared, session: "r", direction: .macToPhone)
        XCTAssertEqual(reply.kind, .relayProbeAnswer)
        XCTAssertNil(gate.claim(session: "r", now: 101), "诊断会话不能开正式连接")
        XCTAssertTrue(gate.claimEcho(session: "r", now: 101))
        XCTAssertFalse(gate.claimEcho(session: "r", now: 102), "一个会话只能认领一次")
    }

    func test_relay_probe_is_denied_for_an_unticked_device_and_expires() throws {
        let mac = Device(), phone = Device()
        var denied = responder(mac: mac, phone: phone, allowed: false)
        let box = try sealedProbe(from: phone, to: mac, session: "r", kind: .relayProbe, at: 100)
        guard case .denied = denied.receiveProbe(session: "r", from: phone.id.uuidString, box: box, now: 100) else {
            return XCTFail("没勾选的设备要明确拒绝")
        }
        XCTAssertFalse(denied.claimEcho(session: "r", now: 100))

        var gate = responder(mac: mac, phone: phone, allowed: true)
        let fresh = try sealedProbe(from: phone, to: mac, session: "e", kind: .relayProbe, at: 100)
        _ = gate.receiveProbe(session: "e", from: phone.id.uuidString, box: fresh, now: 100)
        XCTAssertFalse(gate.claimEcho(session: "e", now: 100 + RemoteSignalResponder.sessionLifetime + 1), "过期")
    }

    // MARK: - 链路矩阵

    func test_filter_drops_link_local_and_keeps_the_requested_family() {
        let description = [
            "a=ice-ufrag:abcd", "a=ice-pwd:efgh",
            "a=candidate:1 1 UDP 2122317823 192.168.1.2 49160 typ host",
            "a=candidate:2 1 UDP 2122317823 169.254.50.3 49161 typ host",
            "a=candidate:3 1 UDP 2122317823 fe80::1c2b:3aff:fe11:2233 49162 typ host",
            "a=candidate:4 1 UDP 2122317823 2408:8207::1 49163 typ host",
            "a=candidate:6 1 UDP 2122317823 fdec:4e30:7a52::1 49164 typ host",
            "a=candidate:5 1 UDP 1686052607 45.76.10.20 50000 typ srflx raddr 0.0.0.0 rport 0",
            "a=end-of-candidates",
        ].joined(separator: "\r\n")
        func labels(_ family: RemoteICEAddressFamily?) -> [String] {
            RemoteICECandidateKind.all(inDescription: RemoteICEDescriptionFilter.keep(description, family: family))
                .map(\.label)
        }
        XCTAssertEqual(labels(nil), ["host-v4", "host-v6", "srflx-v4"], "链路本地与 ULA（USB 线、devicectl 调试隧道）不参与")
        XCTAssertEqual(labels(.ipv4), ["host-v4", "srflx-v4"])
        XCTAssertEqual(labels(.ipv6), ["host-v6"])
        let publicOnly = RemoteICECandidateKind.all(inDescription:
            RemoteICEDescriptionFilter.keep(description, family: nil, publicOnly: true)).map(\.label)
        XCTAssertEqual(publicOnly, ["host-v6", "srflx-v4"], "只走公网：192.168 的私有地址也不用，公网映射留着")
        let kept = RemoteICEDescriptionFilter.keep(description, family: .ipv6)
        XCTAssertTrue(kept.contains("a=ice-ufrag:abcd") && kept.contains("a=ice-pwd:efgh") && kept.contains("a=end-of-candidates"))
    }

    /// libjuice 按地址加进来的先后排检查：公网映射先试，不在本机网段的私有 IPv4 放后面（mini 有 7 个本机 IPv4，原样交时
    /// 手机要过约 350 ms 才轮到能通的那个）。别的行原地不动，同一档里保持原来的先后。
    func test_check_order_puts_reflexive_first_and_private_ipv4_last() {
        let description = [
            "a=ice-ufrag:abcd", "a=ice-pwd:efgh",
            "a=candidate:1 1 UDP 2122317823 192.168.31.3 49160 typ host",
            "a=candidate:2 1 UDP 2122317823 198.18.0.1 49160 typ host",
            "a=candidate:3 1 UDP 2122317823 2408:8207::1 49163 typ host",
            "a=candidate:4 1 UDP 2122317823 10.0.0.2 49160 typ host",
            "a=candidate:5 1 UDP 1686052607 45.76.10.20 50000 typ srflx raddr 0.0.0.0 rport 0",
            "a=candidate:6 1 UDP 16777215 203.0.113.9 3478 typ relay raddr 0.0.0.0 rport 0",
            "a=end-of-candidates", "",
        ].joined(separator: "\r\n")
        let ordered = RemoteICEDescriptionFilter.checkOrdered(description)
        let lines = ordered.components(separatedBy: "\r\n")
        XCTAssertEqual(Array(lines.prefix(2)), ["a=ice-ufrag:abcd", "a=ice-pwd:efgh"])
        XCTAssertEqual(lines.filter { $0.hasPrefix("a=candidate:") }.map { String($0.dropFirst(12).prefix(1)) },
                       ["5", "3", "1", "2", "4", "6"])
        XCTAssertEqual(Array(lines.suffix(2)), ["a=end-of-candidates", ""], "尾巴原样")
        XCTAssertEqual(ordered.count, description.count, "只换顺序，不增不减")

        let split = RemoteICEDescriptionFilter.split(description)
        XCTAssertFalse(split.credentials.contains("a=candidate:"))
        XCTAssertFalse(split.credentials.contains("end-of-candidates"), "对端收集完由加完地址之后再报")
        // 拆出来的候选保持原来的先后：排序由 `RemoteICEAgent.answer` 收集完本机地址之后再按网段排。
        XCTAssertTrue(split.credentials.contains("a=ice-ufrag:abcd") && split.credentials.contains("a=ice-pwd:efgh"))
        XCTAssertEqual(split.candidates.map { String($0.dropFirst(12).prefix(1)) }, ["1", "2", "3", "4", "5", "6"])

        // 本机也在 192.168.31.x：对端同网段的那个多半同一局域网，排最前（免得先走公网映射再换过去、换的那一下丢包）。
        let local = "a=ice-ufrag:x\r\na=candidate:1 1 UDP 2122317823 192.168.31.119 50000 typ host\r\n"
            + "a=candidate:2 1 UDP 1686052607 45.76.10.9 50000 typ srflx raddr 0.0.0.0 rport 0"
        let nearFirst = RemoteICEDescriptionFilter.checkOrdered(description, local: local)
            .components(separatedBy: "\r\n").filter { $0.hasPrefix("a=candidate:") }.map { String($0.dropFirst(12).prefix(1)) }
        XCTAssertEqual(nearFirst, ["1", "5", "3", "2", "4", "6"])

        // 分两拨：能指望的先加，别的私有 IPv4 和中继晚加，不占前面的检查时间槽。
        func ids(_ lines: [String]) -> [String] { lines.map { String($0.dropFirst(12).prefix(1)) } }
        let waves = RemoteICEDescriptionFilter.checkWaves(description, local: local)
        XCTAssertEqual(ids(waves.now), ["1", "5", "3"])
        XCTAssertEqual(ids(waves.later), ["2", "4", "6"])
        let noLocal = RemoteICEDescriptionFilter.checkWaves(description, local: nil)
        XCTAssertEqual(ids(noLocal.now), ["5", "3"])
        XCTAssertEqual(ids(noLocal.later), ["1", "2", "4", "6"])
    }

    func test_public_only_drops_every_private_ipv4_range() {
        func kept(_ address: String) -> Bool {
            let line = "a=candidate:1 1 UDP 2122317823 \(address) 49160 typ host"
            return !RemoteICECandidateKind.all(inDescription:
                RemoteICEDescriptionFilter.keep(line, family: nil, publicOnly: true)).isEmpty
        }
        for address in ["10.1.2.3", "172.16.0.1", "172.31.255.1", "192.168.31.119", "100.64.0.1", "100.127.1.1",
                        "127.0.0.1", "198.18.0.1", "198.19.255.1"] {
            XCTAssertFalse(kept(address), address)
        }
        for address in ["45.76.10.20", "172.32.0.1", "100.128.0.1", "198.20.0.1", "110.53.20.14", "2408:8207::1"] {
            XCTAssertTrue(kept(address), address)
        }
    }

    func test_percentiles_and_summary() {
        let trips = (1...20).map(Double.init)
        let percentiles = RemoteRoundTrips.percentiles(trips)
        XCTAssertEqual(percentiles.p50, 11)
        XCTAssertEqual(percentiles.p95, 19)
        XCTAssertNil(RemoteRoundTrips.percentiles([]).p50)

        var ok = RemotePathProbeResult(mode: .relay, connected: true)
        ok.setupMillis = 300
        ok.roundTripMillis = 40
        ok.roundTripP95Millis = 90
        ok.lossPercent = 0
        let failed = RemotePathProbeResult(mode: .relay, connected: false, failure: "超时")
        let direct = RemotePathProbeResult(mode: .directIPv6, connected: false, failure: "所有候选地址都不通")
        let summaries = RemotePathProbeSummary.summarize([ok, failed, direct])
        XCTAssertEqual(summaries.map(\.mode), [.directIPv6, .relay])
        let relay = try? XCTUnwrap(summaries.last)
        XCTAssertEqual(relay?.attempts, 2)
        XCTAssertEqual(relay?.successes, 1)
        XCTAssertEqual(relay?.medianSetupMillis, 300)
        XCTAssertEqual(relay?.medianRoundTripMillis, 40)
        XCTAssertEqual(summaries.first?.successes, 0)
    }

    func test_body_without_ice_still_decodes() throws {
        let json = #"{"kind":"offer","deviceID":"7D4E9A2C-1F1B-4B7E-9C55-0A6E2D8F3B11","sentAt":1,"nonce":"AAAA"}"#
        let body = try JSONDecoder().decode(RemoteSignalBody.self, from: Data(json.utf8))
        XCTAssertNil(body.ice)
    }

    // MARK: - 候选地址与记录

    func test_candidate_kind_keeps_only_type_and_family() throws {
        let host = try XCTUnwrap(RemoteICECandidateKind(sdp: "a=candidate:1 1 UDP 2122317823 192.168.1.2 49160 typ host"))
        XCTAssertEqual(host.label, "host-v4")
        let mapped = try XCTUnwrap(RemoteICECandidateKind(sdp: "a=candidate:2 1 UDP 1686052607 2408:8207::1 49160 typ srflx raddr 0.0.0.0 rport 0"))
        XCTAssertEqual(mapped.label, "srflx-v6")
        XCTAssertNil(RemoteICECandidateKind(sdp: "a=ice-ufrag:abcd"))
        XCTAssertEqual(RemoteICECandidateKind.all(inDescription: sampleDescription).map(\.label), ["host-v4"])
    }

    func test_log_keeps_the_newest_records() {
        let suite = "remote.ice.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = RemotePathMatrixLog(defaults: defaults)
        for index in 0..<(RemotePathMatrixLog.limit + 5) {
            var result = RemotePathProbeResult()
            result.note = "\(index)"
            log.append([result])
        }
        XCTAssertEqual(log.load().count, RemotePathMatrixLog.limit)
        XCTAssertEqual(log.load().first?.note, "\(RemotePathMatrixLog.limit + 4)")
        log.clear()
        XCTAssertTrue(log.load().isEmpty)
    }

    func test_last_run_is_the_newest_run_in_order() {
        let suite = "remote.ice.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = RemotePathMatrixLog(defaults: defaults)
        XCTAssertTrue(log.lastRun().isEmpty)
        let old = UUID(), new = UUID()
        log.append([RemotePathProbeResult(runID: old, round: 1, mode: .relay)])
        log.append([RemotePathProbeResult(runID: new, round: 1, mode: .directIPv6)])
        log.append([RemotePathProbeResult(runID: new, round: 1, mode: .relay)])
        XCTAssertEqual(log.lastRun().map(\.mode), [.directIPv6, .relay], "只取最近一次，按时间先后")
    }

    func test_summary_line_has_no_address() {
        var result = RemoteICEProbeResult()
        result.connected = true
        result.selectedLocal = RemoteICECandidateKind(sdp: "a=candidate:1 1 UDP 1 203.0.113.9 1234 typ srflx")?.label
        XCTAssertFalse(result.summaryLine.contains("203.0.113.9"))
        XCTAssertTrue(result.summaryLine.contains("srflx-v4"))
    }

    // MARK: - 真实 libjuice

    /// 两个 agent 按真实流程交换描述：一方先给描述（controlling），另一方先设对端（controlled）。
    func test_two_agents_connect_and_exchange_datagrams_over_host_candidates() async throws {
        let phone = try XCTUnwrap(RemoteICEProbeSession(stunHost: nil, stunPort: 0, echoes: false))
        let mac = try XCTUnwrap(RemoteICEProbeSession(stunHost: nil, stunPort: 0, echoes: true))
        defer {
            phone.close()
            mac.close()
        }
        XCTAssertTrue(phone.gather())
        await phone.waitForGathering(limit: .seconds(3))
        let offer = try XCTUnwrap(phone.localDescription())
        guard !RemoteICECandidateKind.all(inDescription: offer).isEmpty else {
            throw XCTSkip("这台机器没有非回环网卡，没有候选地址可打")
        }
        XCTAssertTrue(mac.setRemote(offer))
        XCTAssertTrue(mac.gather())
        await mac.waitForGathering(limit: .seconds(3))
        let answer = try XCTUnwrap(mac.localDescription())
        XCTAssertTrue(phone.setRemote(answer))

        let connected = await phone.waitForConnection(limit: .seconds(10))
        XCTAssertTrue(connected, "phone \(phone.currentPhase)，mac \(mac.currentPhase)")
        let macConnected = await mac.waitForConnection(limit: .seconds(10))
        XCTAssertTrue(macConnected)
        XCTAssertNotNil(phone.selectedCandidates())

        let measured = await phone.measure(count: 10, interval: .milliseconds(10), settle: .milliseconds(200))
        XCTAssertEqual(measured.lossPercent, 0)
        XCTAssertNotNil(measured.roundTripMillis)
        print("[打洞探针·本机] 往返 \(measured.roundTripMillis ?? -1) ms")
    }

    /// 对端的候选地址都不通时，要在时限内明确失败，不能一直挂着。
    func test_unreachable_candidates_never_connect() async throws {
        let phone = try XCTUnwrap(RemoteICEProbeSession(stunHost: nil, stunPort: 0, echoes: false))
        defer { phone.close() }
        XCTAssertTrue(phone.gather())
        await phone.waitForGathering(limit: .seconds(3))
        _ = phone.localDescription()
        // 203.0.113.0/24 是文档专用地址，不会有人回应。
        let remote = "a=ice-ufrag:abcd\r\na=ice-pwd:0123456789012345678901\r\n"
            + "a=candidate:1 1 UDP 2122317823 203.0.113.9 49160 typ host\r\na=end-of-candidates\r\n"
        XCTAssertTrue(phone.setRemote(remote))
        let connected = await phone.waitForConnection(limit: .seconds(2))
        XCTAssertFalse(connected)
    }

    func test_closing_twice_and_using_after_close_is_safe() throws {
        let agent = try XCTUnwrap(RemoteICEAgent(stunHost: nil, stunPort: 0, queue: DispatchQueue(label: "test.ice"),
                                                 handlers: RemoteICEAgent.Handlers()))
        agent.close()
        agent.close()
        XCTAssertFalse(agent.gather())
        XCTAssertFalse(agent.send(Data([1])))
        XCTAssertNil(agent.localDescription())
    }
}
