import CryptoKit
import XCTest
@preconcurrency import Network
@testable import uTerm

/// 网络诊断：结论怎么选、缺前提时怎么报，以及局域网那条路经真实服务端走一遍（不要中继）。
@MainActor
final class RemotePathMatrixTests: XCTestCase {

    private func summary(_ mode: RemotePathProbeMode, ok: Int, of attempts: Int = 3,
                         roundTrip: Double? = nil) -> RemotePathProbeSummary {
        RemotePathProbeSummary(mode: mode, attempts: attempts, successes: ok, medianSetupMillis: ok > 0 ? 100 : nil,
                               medianRoundTripMillis: ok > 0 ? roundTrip : nil, medianP95Millis: nil,
                               meanLossPercent: ok > 0 ? 0 : nil)
    }

    // MARK: - 结论

    func test_verdict_follows_the_real_connection_order() {
        let all = [summary(.localNetwork, ok: 3, roundTrip: 4), summary(.directIPv6, ok: 3, roundTrip: 30),
                   summary(.directIPv4, ok: 3, roundTrip: 20), summary(.relay, ok: 3, roundTrip: 100)]
        XCTAssertEqual(RemotePathVerdict.chosen(all)?.mode, .localNetwork, "局域网通就走局域网")
        XCTAssertEqual(RemotePathVerdict.chosen(all, skipsLocalNetwork: true)?.mode, .directIPv4,
                       "只走公网：两族直连都通时取往返更短的")
        let noDirect = [summary(.localNetwork, ok: 0), summary(.directIPv6, ok: 0), summary(.directIPv4, ok: 0),
                        summary(.relay, ok: 2, roundTrip: 110)]
        XCTAssertEqual(RemotePathVerdict.chosen(noDirect)?.mode, .relay, "打不通落到中继")
        let partial = [summary(.directIPv6, ok: 1, roundTrip: 50), summary(.relay, ok: 3, roundTrip: 100)]
        XCTAssertEqual(RemotePathVerdict.chosen(partial)?.mode, .directIPv6, "成功过一次就算这条路可用")
        XCTAssertNil(RemotePathVerdict.chosen([summary(.relay, ok: 0), summary(.localNetwork, ok: 0)]), "都不通")
    }

    func test_summaries_follow_the_mode_order() {
        let results = [RemotePathProbeResult(mode: .relay), RemotePathProbeResult(mode: .localNetwork),
                       RemotePathProbeResult(mode: .directIPv4)]
        XCTAssertEqual(RemotePathProbeSummary.summarize(results).map(\.mode), [.localNetwork, .directIPv4, .relay])
    }

    // MARK: - 缺前提

    func test_missing_lan_or_relay_fails_with_a_reason_without_touching_the_network() async {
        let phone = RemoteIdentityStore(storage: RemoteMemoryStorage())
        let mac = RemotePeer(id: UUID(), name: "测试 Mac", publicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
                             pairedAt: Date())
        var runner = RemotePathMatrixRunner(identity: phone, localID: UUID())
        runner.relayUnavailable = "Mac 不在中继上"
        let results = await runner.run(mac: mac, rounds: 1) { _ in }
        XCTAssertEqual(results.map(\.mode), RemotePathProbeMode.allCases)
        XCTAssertTrue(results.allSatisfy { !$0.connected })
        XCTAssertEqual(results.first?.failure, "Mac 不在这个局域网里")
        XCTAssertEqual(Set(results.dropFirst().compactMap(\.failure)), ["Mac 不在中继上"])
    }

    // MARK: - 局域网

    func test_lan_probe_connects_and_measures_round_trips_through_a_real_server() async throws {
        let server = RemoteHostServer(registry: TerminalSessionRegistry(),
                                      identity: RemoteIdentityStore(storage: RemoteMemoryStorage()),
                                      localName: "测试 Mac", localID: UUID(), advertises: false)
        server.start()
        defer { server.stop() }
        let deadline = Date().addingTimeInterval(5)
        while server.port == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let port = try XCTUnwrap(server.port.flatMap { NWEndpoint.Port(rawValue: $0) })
        let phone = RemoteIdentityStore(storage: RemoteMemoryStorage())
        try server.trust(RemotePeer(id: RemoteLocalDevice.id(), name: "测试 iPhone",
                                    publicKey: try phone.localIdentity().publicKey.rawRepresentation, pairedAt: Date()))
        let target = RemoteLANTarget(macName: "测试 Mac", endpoint: .hostPort(host: "127.0.0.1", port: port),
                                     expectedPeer: nil)

        let result = await RemoteLANProbe(identity: phone).run(target, pings: 10)
        XCTAssertTrue(result.connected, result.failure ?? "")
        XCTAssertEqual(result.mode, .localNetwork)
        XCTAssertEqual(result.lossPercent, 0)
        XCTAssertNotNil(result.roundTripMillis)
        XCTAssertNotNil(result.setupMillis)
    }

    /// Mac 不认识这台手机：要等 Mac 上的人同意，诊断不能一直等，报原因收工。
    func test_lan_probe_does_not_wait_for_approval_forever() async throws {
        let server = RemoteHostServer(registry: TerminalSessionRegistry(),
                                      identity: RemoteIdentityStore(storage: RemoteMemoryStorage()),
                                      localName: "测试 Mac", localID: UUID(), advertises: false)
        server.start()
        defer { server.stop() }
        let deadline = Date().addingTimeInterval(5)
        while server.port == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let port = try XCTUnwrap(server.port.flatMap { NWEndpoint.Port(rawValue: $0) })
        let target = RemoteLANTarget(macName: "测试 Mac", endpoint: .hostPort(host: "127.0.0.1", port: port),
                                     expectedPeer: nil)
        let started = Date()
        let result = await RemoteLANProbe(identity: RemoteIdentityStore(storage: RemoteMemoryStorage())).run(target)
        XCTAssertFalse(result.connected)
        XCTAssertNotNil(result.failure)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }
}
