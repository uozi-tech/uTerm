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

    func test_log_keeps_the_newest_hundred() {
        let suite = "remote.ice.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = RemoteICEProbeLog(defaults: defaults)
        for index in 0..<105 {
            var result = RemoteICEProbeResult()
            result.note = "\(index)"
            log.append(result)
        }
        XCTAssertEqual(log.load().count, 100)
        XCTAssertEqual(log.load().first?.note, "104")
        log.clear()
        XCTAssertTrue(log.load().isEmpty)
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
