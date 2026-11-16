import CryptoKit
import Foundation
import XCTest
@testable import uTerm

/// 组里的 Mac 的两种记录（`host` / `grant`）与中继包：格式、签名覆盖哪些字段、解码时丢掉什么。
/// 谁写、谁收、谁问见 `RemoteDeviceGroupHostsTests`。
final class RemoteGroupHostRecordsTests: XCTestCase {
    private let clock = RemoteGroupTime(Date(timeIntervalSince1970: 1_800_000_000))
    private let signerKey = Curve25519.Signing.PrivateKey()

    private func device(_ name: String, signing: Curve25519.Signing.PrivateKey = .init()) -> RemoteGroupDevice {
        RemoteGroupDevice(id: UUID(), name: name, model: nil, platform: RemoteDevicePlatform.mobile.rawValue,
                          publicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
                          signingKey: signing.publicKey.rawRepresentation, updatedAt: Date())
    }

    private lazy var signer = device("iPhone", signing: signerKey)
    private lazy var target = device("iPad")
    private let host = RemoteGroupHostInfo(id: UUID(), name: "Mac mini",
                                           publicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
                                           model: "Mac mini", platform: RemoteDevicePlatform.mac.rawValue)

    private func grant(outcome: String = "added", reason: String? = "原因", internetAccess: Bool? = true,
                       relay: Data? = Data([1, 2, 3])) throws -> RemoteGroupHostGrant {
        try RemoteGroupHostGrant.make(device: target, host: host, outcome: outcome, reason: reason,
                                      internetAccess: internetAccess, relay: relay, signer: signer, signedAt: clock,
                                      key: signerKey)
    }

    private func roundTrip(_ record: RemoteGroupRecord) throws -> RemoteGroupRecord? {
        RemoteGroupRecord.decode(try record.encoded())
    }

    func test_accounts_follow_the_spec() {
        let a = UUID(), b = UUID(), c = UUID()
        XCTAssertEqual(RemoteGroupHost.account(host: a, signer: b), "host.\(a.uuidString).\(b.uuidString)")
        XCTAssertEqual(RemoteGroupHostGrant.account(device: a, host: b, signer: c),
                       "grant.\(a.uuidString).\(b.uuidString).\(c.uuidString)")
    }

    func test_host_and_grant_round_trip() throws {
        let record = try RemoteGroupHost.make(host: host, signer: signer, signedAt: clock, key: signerKey)
        XCTAssertEqual(try roundTrip(.host(record)), .host(record))
        for value in [try grant(), try grant(reason: nil, internetAccess: nil, relay: nil), try grant(internetAccess: false)] {
            XCTAssertEqual(try roundTrip(.grant(value)), .grant(value))
        }
        let snapshotRoster = RemoteGroupRoster(storage: RemoteMemorySyncedStorage())
        try snapshotRoster.save(.host(record))
        try snapshotRoster.save(.grant(try grant()))
        let snapshot = snapshotRoster.load()
        XCTAssertEqual(snapshot.hosts, [record])
        XCTAssertEqual(snapshot.grants.count, 1)
    }

    func test_grant_signature_covers_every_field() throws {
        let original = try grant()
        let otherKey = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let mutations: [(String, (inout RemoteGroupHostGrant) -> Void)] = [
            ("deviceID", { $0.deviceID = UUID() }),
            ("publicKey", { $0.publicKey = otherKey }),
            ("signingKey", { $0.signingKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation }),
            ("host.id", { $0.host.id = UUID() }),
            ("host.name", { $0.host.name = "别的 Mac" }),
            ("host.publicKey", { $0.host.publicKey = otherKey }),
            ("host.model", { $0.host.model = nil }),
            ("host.platform", { $0.host.platform = "mobile" }),
            ("outcome", { $0.outcome = "rejected" }),
            ("reason", { $0.reason = nil }),
            ("reason empty", { $0.reason = "" }),
            ("internetAccess", { $0.internetAccess = false }),
            ("internetAccess nil", { $0.internetAccess = nil }),
            ("relay", { $0.relay = Data([1, 2, 4]) }),
            ("relay nil", { $0.relay = nil }),
            ("signer", { $0.signer = UUID() }),
            ("signerKey", { $0.signerKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation }),
            ("signedAt", { $0.signedAt = $0.signedAt.next }),
        ]
        for (name, mutate) in mutations {
            var changed = original
            mutate(&changed)
            XCTAssertFalse(changed.hasValidSignature, name)
            XCTAssertNil(try roundTrip(.grant(changed)), name)
        }
        XCTAssertNotNil(try roundTrip(.grant(original)))
    }

    func test_host_signature_covers_every_field() throws {
        let original = try RemoteGroupHost.make(host: host, signer: signer, signedAt: clock, key: signerKey)
        let mutations: [(String, (inout RemoteGroupHost) -> Void)] = [
            ("host.id", { $0.host.id = UUID() }),
            ("host.name", { $0.host.name = "别的 Mac" }),
            ("host.publicKey", { $0.host.publicKey = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation }),
            ("host.model", { $0.host.model = "" }),
            ("host.platform", { $0.host.platform = nil }),
            ("signer", { $0.signer = UUID() }),
            ("signerKey", { $0.signerKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation }),
            ("signedAt", { $0.signedAt = $0.signedAt.next }),
        ]
        for (name, mutate) in mutations {
            var changed = original
            mutate(&changed)
            XCTAssertNil(try roundTrip(.host(changed)), name)
        }
    }

    func test_signatures_do_not_transfer_between_record_kinds() throws {
        XCTAssertEqual(Set([RemoteGroupHost.label, RemoteGroupHostGrant.label, RemoteGroupAdmit.label, RemoteGroupRemove.label,
                            RemoteGroupRelaySeal.label]).count, 5)
        // 同一把钥匙签的 host，签名搬到 grant 上验不过。
        let record = try RemoteGroupHost.make(host: host, signer: signer, signedAt: clock, key: signerKey)
        var moved = try grant()
        moved.signature = record.signature
        XCTAssertFalse(moved.hasValidSignature)
    }

    func test_malformed_grants_and_hosts_are_dropped() throws {
        // 替自己开通。
        var selfVouch = target
        selfVouch.signingKey = signer.signingKey
        XCTAssertNil(try roundTrip(.grant(RemoteGroupHostGrant.make(device: selfVouch, host: host, outcome: "added", reason: nil,
                                                                    internetAccess: nil, relay: nil, signer: signer,
                                                                    signedAt: clock, key: signerKey))))
        // 替 Mac 向它自己开通。
        var macItself = target
        macItself.id = host.id
        XCTAssertNil(try roundTrip(.grant(RemoteGroupHostGrant.make(device: macItself, host: host, outcome: "added", reason: nil,
                                                                    internetAccess: nil, relay: nil, signer: signer,
                                                                    signedAt: clock, key: signerKey))))
        XCTAssertNil(try roundTrip(.grant(try grant(outcome: ""))), "空结果")
        XCTAssertNil(try roundTrip(.grant(try grant(relay: Data()))), "空的中继包")
        var shortKey = host
        shortKey.publicKey = Data(repeating: 1, count: 31)
        XCTAssertNil(try roundTrip(.grant(RemoteGroupHostGrant.make(device: target, host: shortKey, outcome: "added",
                                                                    reason: nil, internetAccess: nil, relay: nil,
                                                                    signer: signer, signedAt: clock, key: signerKey))))
        XCTAssertNil(try roundTrip(.host(RemoteGroupHost.make(host: shortKey, signer: signer, signedAt: clock, key: signerKey))))
        var unsigned = try grant()
        unsigned.signature = Data(repeating: 0, count: 64)
        XCTAssertNil(try roundTrip(.grant(unsigned)))
        // 「我配对过我自己」。
        var macSelf = host
        macSelf.id = signer.id
        XCTAssertNil(try roundTrip(.host(RemoteGroupHost.make(host: macSelf, signer: signer, signedAt: clock, key: signerKey))))
    }

    func test_canonical_optionals_are_unambiguous() {
        func bytes(_ build: (inout RemoteGroupCanonical) -> Void) -> Data {
            var canonical = RemoteGroupCanonical(label: "t")
            build(&canonical)
            return canonical.bytes
        }
        let data = [bytes { $0.appendOptional(Data?.none) }, bytes { $0.appendOptional(Data()) },
                    bytes { $0.appendOptional(Data([0])) }]
        let flags = [bytes { $0.appendOptional(Bool?.none) }, bytes { $0.appendOptional(false) },
                     bytes { $0.appendOptional(true) }]
        XCTAssertEqual(Set(data).count, 3, "nil、空数据、有内容各不相同")
        XCTAssertEqual(Set(flags).count, 3, "nil、false、true 各不相同")
        // 后面还有字段时也切不错：nil + 一个字段 与 有值（内容是那个字段）不同。
        XCTAssertNotEqual(bytes { $0.appendOptional(Data?.none); $0.append("x") }, bytes { $0.appendOptional(Data("x".utf8)) })
    }

    // MARK: - 中继包

    func test_relay_seal_opens_only_for_the_pair_and_the_bound_ids() throws {
        let a = Curve25519.KeyAgreement.PrivateKey(), b = Curve25519.KeyAgreement.PrivateKey()
        let c = Curve25519.KeyAgreement.PrivateKey()
        let signerID = UUID(), targetID = UUID(), hostID = UUID()
        let relay = RemoteRelayConfig(name: "r", host: "relay.example.invalid", port: 1, relayID: "rid",
                                      key: P256.Signing.PrivateKey().rawRepresentation.base64EncodedString(),
                                      scope: hostID.uuidString, cert: Data([1]).base64EncodedString(), expires: 9_999_999_999)
        let sealKey = try RemoteGroupRelaySeal.key(local: a, remote: b.publicKey.rawRepresentation)
        let box = try RemoteGroupRelaySeal.seal(relay, key: sealKey, signer: signerID, target: targetID, host: hostID)
        let openKey = try RemoteGroupRelaySeal.key(local: b, remote: a.publicKey.rawRepresentation)
        XCTAssertEqual(RemoteGroupRelaySeal.open(box, key: openKey, signer: signerID, target: targetID, host: hostID), relay)
        let third = try RemoteGroupRelaySeal.key(local: c, remote: a.publicKey.rawRepresentation)
        XCTAssertNil(RemoteGroupRelaySeal.open(box, key: third, signer: signerID, target: targetID, host: hostID))
        XCTAssertNil(RemoteGroupRelaySeal.open(box, key: openKey, signer: UUID(), target: targetID, host: hostID))
        XCTAssertNil(RemoteGroupRelaySeal.open(box, key: openKey, signer: signerID, target: UUID(), host: hostID))
        XCTAssertNil(RemoteGroupRelaySeal.open(box, key: openKey, signer: signerID, target: targetID, host: UUID()))
        var flipped = box
        flipped[flipped.count / 2] ^= 1
        XCTAssertNil(RemoteGroupRelaySeal.open(flipped, key: openKey, signer: signerID, target: targetID, host: hostID))
        XCTAssertNil(RemoteGroupRelaySeal.open(Data([1, 2]), key: openKey, signer: signerID, target: targetID, host: hostID))
        XCTAssertThrowsError(try RemoteGroupRelaySeal.key(local: a, remote: Data(repeating: 0, count: 32)), "小阶点")
        XCTAssertThrowsError(try RemoteGroupRelaySeal.key(local: a, remote: Data(repeating: 1, count: 31)))
    }
}
