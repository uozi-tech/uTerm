import CryptoKit
import Foundation
import XCTest
@testable import uTerm

/// 设备组名册的记录格式、签名、加入用的 CPace 参数与封包、组员名单算法。整套流程与攻击场景见 `RemoteDeviceGroupTests`。
final class RemoteGroupRosterTests: XCTestCase {
    private let clock = Date(timeIntervalSince1970: 1_800_000_000)
    /// 每台测试设备的签名私钥（按公钥找），给它签加入信息用。
    private var signingKeys: [Data: Curve25519.Signing.PrivateKey] = [:]

    private func device(_ name: String, signing: Curve25519.Signing.PrivateKey = .init()) -> RemoteGroupDevice {
        signingKeys[signing.publicKey.rawRepresentation] = signing
        return RemoteGroupDevice(id: UUID(), name: name, model: "iPhone 16 Pro", platform: RemoteDevicePlatform.mobile.rawValue,
                                 publicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
                                 signingKey: signing.publicKey.rawRepresentation, updatedAt: clock)
    }

    /// `admitter` 签的、`device` 的加入信息。
    private func admission(of device: RemoteGroupDevice, by admitter: RemoteGroupDevice,
                           at seconds: TimeInterval = 0) -> RemoteGroupAdmission {
        try! RemoteGroupAdmission.make(device: device, admitter: admitter,
                                       admittedAt: RemoteGroupTime(clock.addingTimeInterval(seconds)),
                                       key: signingKeys[admitter.signingKey]!)
    }

    private func roundTrip(_ record: RemoteGroupRecord) throws -> RemoteGroupRecord? {
        RemoteGroupRecord.decode(try record.encoded())
    }

    // MARK: - 存哪

    func test_roster_uses_its_own_service() {
        XCTAssertEqual(RemoteGroupRoster.service, "com.uozi.uTerm.remote.group")
        XCTAssertNotEqual(RemoteGroupRoster.service, RemoteLegacyDevices.service)
        XCTAssertNotEqual(RemoteGroupLocalStore.stateAccount, RemoteIdentityStore.vouchAccount)
    }

    func test_accounts_follow_the_spec() {
        let a = UUID(), b = UUID()
        XCTAssertEqual(RemoteGroupRecord.deviceAccount(a), "device.\(a.uuidString)")
        XCTAssertEqual(RemoteGroupJoin.account(a), "join.\(a.uuidString)")
        XCTAssertEqual(RemoteGroupAnswer.account(candidate: a, member: b), "answer.\(a.uuidString).\(b.uuidString)")
        XCTAssertEqual(RemoteGroupDone.account(candidate: a, member: b), "done.\(a.uuidString).\(b.uuidString)")
        XCTAssertEqual(RemoteGroupAdmit.account(device: a, signer: b), "admit.\(a.uuidString).\(b.uuidString)")
        XCTAssertEqual(RemoteGroupRemove.account(device: a, signer: b), "remove.\(a.uuidString).\(b.uuidString)")
    }

    // MARK: - 信封

    func test_every_record_round_trips() throws {
        let key = Curve25519.Signing.PrivateKey()
        let signer = device("Mac", signing: key)
        let phone = device("iPhone")
        let join = RemoteGroupJoin(device: phone, sid: Data(repeating: 1, count: 16), share: Data(repeating: 2, count: 32),
                                   createdAt: clock)
        let answer = RemoteGroupAnswer(candidate: phone.id, sid: join.sid, member: signer, share: Data(repeating: 3, count: 32),
                                       confirmation: Data(repeating: 4, count: 64), package: Data([5]), createdAt: clock)
        let done = RemoteGroupDone(candidate: phone.id, member: signer.id, sid: join.sid,
                                   confirmation: Data(repeating: 6, count: 64), entry: Data([7]), createdAt: clock)
        let admit = try RemoteGroupAdmit.make(device: phone, admission: admission(of: phone, by: signer), signer: signer,
                                              signedAt: RemoteGroupTime(clock), key: key)
        let remove = try RemoteGroupRemove.make(target: phone, admission: admission(of: phone, by: signer),
                                                removedAt: RemoteGroupTime(clock), signer: signer, key: key)
        for record in [RemoteGroupRecord.device(phone), .join(join), .answer(answer), .done(done), .admit(admit), .remove(remove)] {
            XCTAssertEqual(try roundTrip(record), record)
        }
    }

    func test_malformed_records_are_dropped() throws {
        let phone = device("iPhone")
        var shortKey = phone
        shortKey.signingKey = Data(repeating: 1, count: 31)
        XCTAssertNil(try roundTrip(.device(shortKey)), "Ed25519 公钥不是 32 字节")
        var shortX = phone
        shortX.publicKey = Data(repeating: 1, count: 33)
        XCTAssertNil(try roundTrip(.device(shortX)), "X25519 公钥不是 32 字节")

        let join = RemoteGroupJoin(device: phone, sid: Data(repeating: 1, count: 16), share: Data(repeating: 2, count: 32),
                                   createdAt: clock)
        var badSid = join
        badSid.sid = Data(repeating: 1, count: 15)
        XCTAssertNil(try roundTrip(.join(badSid)), "sid 必须 16 字节")
        var badShare = join
        badShare.share = Data(repeating: 2, count: 31)
        XCTAssertNil(try roundTrip(.join(badShare)), "份额必须 32 字节")
        var badDevice = join
        badDevice.device = shortKey
        XCTAssertNil(try roundTrip(.join(badDevice)))

        let answer = RemoteGroupAnswer(candidate: phone.id, sid: join.sid, member: device("Mac"), share: join.share,
                                       confirmation: Data(repeating: 4, count: 63), package: Data([5]), createdAt: clock)
        XCTAssertNil(try roundTrip(.answer(answer)), "确认标签必须 64 字节")
        var emptyPackage = answer
        emptyPackage.confirmation = Data(repeating: 4, count: 64)
        emptyPackage.package = Data()
        XCTAssertNil(try roundTrip(.answer(emptyPackage)))

        let done = RemoteGroupDone(candidate: phone.id, member: UUID(), sid: Data(repeating: 1, count: 17),
                                   confirmation: Data(repeating: 6, count: 64), entry: Data([7]), createdAt: clock)
        XCTAssertNil(try roundTrip(.done(done)))

        XCTAssertNil(RemoteGroupRecord.decode(Data(#"{"v":2,"record":"device"}"#.utf8)), "不认识的版本跳过")
        XCTAssertNil(RemoteGroupRecord.decode(Data(#"{"v":1,"record":"host"}"#.utf8)), "不认识的记录跳过")
        XCTAssertNil(RemoteGroupRecord.decode(Data(#"{"v":1,"record":"admit"}"#.utf8)))
        XCTAssertNil(RemoteGroupRecord.decode(Data("garbage".utf8)))
    }

    // MARK: - 签名

    func test_admit_signature_covers_every_field() throws {
        let key = Curve25519.Signing.PrivateKey()
        let signer = device("Mac", signing: key)
        let phone = device("iPhone")
        let admit = try RemoteGroupAdmit.make(device: phone, admission: admission(of: phone, by: signer), signer: signer,
                                              signedAt: RemoteGroupTime(clock), key: key)
        XCTAssertTrue(admit.hasValidSignature)
        let other = device("Other")
        let tampers: [(String, (inout RemoteGroupAdmit) -> Void)] = [
            ("名字", { $0.device.name = "Mac mini" }),
            ("机型", { $0.device.model = nil }),
            ("机型空串", { $0.device.model = "" }),
            ("platform", { $0.device.platform = RemoteDevicePlatform.mac.rawValue }),
            ("设备 ID", { $0.device.id = other.id }),
            ("X25519", { $0.device.publicKey = other.publicKey }),
            ("Ed25519", { $0.device.signingKey = other.signingKey }),
            ("登记时间", { $0.device.updatedAt = self.clock.addingTimeInterval(1) }),
            ("添加者", { $0.admission.admitterID = other.id }),
            ("添加者钥匙", { $0.admission.admitterKey = other.signingKey }),
            ("加入时间", { $0.admission.admittedAt = $0.admission.admittedAt.next }),
            ("签名者", { $0.signer = other.id }),
            ("签名时间", { $0.signedAt = $0.signedAt.next }),
            ("最初添加者的签名", { $0.admission.signature = Data(repeating: 9, count: 64) }),
        ]
        for (field, tamper) in tampers {
            var forged = admit
            tamper(&forged)
            XCTAssertFalse(forged.hasValidSignature, "改了\(field)签名就不对")
            XCTAssertNil(try roundTrip(.admit(forged)), "改了\(field)解码时就丢掉")
        }
        var swappedSigner = admit
        swappedSigner.signerKey = other.signingKey
        XCTAssertFalse(swappedSigner.hasValidSignature, "换了签名者的钥匙，原签名验不过")
    }

    func test_remove_signature_covers_every_field() throws {
        let key = Curve25519.Signing.PrivateKey()
        let signer = device("Mac", signing: key)
        let phone = device("iPhone")
        let remove = try RemoteGroupRemove.make(target: phone, admission: admission(of: phone, by: signer),
                                                removedAt: RemoteGroupTime(clock), signer: signer, key: key)
        XCTAssertTrue(remove.hasValidSignature)
        let other = device("Other")
        let tampers: [(String, (inout RemoteGroupRemove) -> Void)] = [
            ("设备 ID", { $0.deviceID = other.id }),
            ("X25519", { $0.publicKey = other.publicKey }),
            ("Ed25519", { $0.signingKey = other.signingKey }),
            ("时间", { $0.removedAt = $0.removedAt.next }),
            ("签名者", { $0.signer = other.id }),
            ("签名者钥匙", { $0.signerKey = other.signingKey }),
            ("带的加入信息", { $0.admission = nil }),
        ]
        for (field, tamper) in tampers {
            var forged = remove
            tamper(&forged)
            XCTAssertFalse(forged.hasValidSignature, "改了\(field)签名就不对")
        }
    }

    func test_signatures_are_bound_to_their_record_kind() throws {
        let key = Curve25519.Signing.PrivateKey()
        let signer = device("Mac", signing: key)
        let target = device("iPhone")
        let remove = try RemoteGroupRemove.make(target: target, admission: nil, removedAt: RemoteGroupTime(clock),
                                                signer: signer, key: key)
        var admit = try RemoteGroupAdmit.make(device: target, admission: admission(of: target, by: signer), signer: signer,
                                              signedAt: RemoteGroupTime(clock), key: key)
        admit.signature = remove.signature
        XCTAssertFalse(admit.hasValidSignature, "remove 的签名搬不到 admit 上")
        XCTAssertTrue(admit.signedBytes.starts(with: CPace.prependLength(Data(RemoteGroupAdmit.label.utf8))))
        XCTAssertTrue(remove.signedBytes.starts(with: CPace.prependLength(Data(RemoteGroupRemove.label.utf8))))
        XCTAssertNotEqual(RemoteGroupAdmit.label, RemoteGroupRemove.label)
    }

    func test_canonical_encoding_has_no_ambiguity() {
        var a = RemoteGroupCanonical(label: "x")
        a.append("ab")
        a.append("c")
        var b = RemoteGroupCanonical(label: "x")
        b.append("a")
        b.append("bc")
        XCTAssertNotEqual(a.bytes, b.bytes, "每段带长度前缀，换个切法拼不出同样的字节")
        var none = RemoteGroupCanonical(label: "x")
        none.appendOptional(String?.none)
        var empty = RemoteGroupCanonical(label: "x")
        empty.appendOptional("")
        XCTAssertNotEqual(none.bytes, empty.bytes, "nil 与空串分得开")
    }

    func test_signature_survives_a_non_whole_millisecond_registration_time() throws {
        let key = Curve25519.Signing.PrivateKey()
        let signer = device("Mac", signing: key)
        var odd = device("iPhone")
        odd.updatedAt = Date(timeIntervalSince1970: 1_800_000_000.123_456_789)
        let admit = try RemoteGroupAdmit.make(device: odd, admission: admission(of: odd, by: signer), signer: signer,
                                              signedAt: RemoteGroupTime(clock), key: key)
        guard case .admit(let decoded) = try XCTUnwrap(try roundTrip(.admit(admit))) else { return XCTFail() }
        XCTAssertTrue(decoded.hasValidSignature)
    }

    func test_group_time_is_exact_through_json() throws {
        let time = RemoteGroupTime(Date(timeIntervalSince1970: 1_800_000_000.987))
        XCTAssertEqual(time.milliseconds, 1_800_000_000_987)
        let decoded = try JSONDecoder().decode(RemoteGroupTime.self, from: JSONEncoder().encode(time))
        XCTAssertEqual(decoded, time)
        XCTAssertEqual(RemoteGroupTime(milliseconds: .max).next.milliseconds, .max, "到顶不回绕")
        XCTAssertEqual(RemoteGroupTime(Date(timeIntervalSince1970: .infinity)).milliseconds, 0, "非有限值不崩")
    }

    // MARK: - 核对码与 CPace

    func test_codes_are_six_ascii_digits() {
        for _ in 0..<50 {
            let code = RemoteGroupJoinCrypto.newCode()
            XCTAssertEqual(code.count, 6)
            XCTAssertNotNil(RemoteGroupJoinCrypto.normalizedCode(code))
        }
        XCTAssertEqual(RemoteGroupJoinCrypto.normalizedCode("123 456"), "123456")
        XCTAssertEqual(RemoteGroupJoinCrypto.normalizedCode("123-456"), "123456")
        XCTAssertNil(RemoteGroupJoinCrypto.normalizedCode("12345"))
        XCTAssertNil(RemoteGroupJoinCrypto.normalizedCode("1234567"))
        XCTAssertNil(RemoteGroupJoinCrypto.normalizedCode("１２３４５６"), "全角数字不算：两端的口令字节必须一样")
        XCTAssertEqual(RemoteGroupJoinCrypto.newSessionID().count, 16)
    }

    func test_join_handshake_agrees_only_on_the_same_code() throws {
        let candidate = device("iPhone"), member = device("Mac")
        let sid = RemoteGroupJoinCrypto.newSessionID()
        let a = try RemoteGroupJoinCrypto.session(.initiator, code: "123456", candidate: candidate.id, sid: sid, local: candidate)
        let join = RemoteGroupJoin(device: candidate, sid: sid, share: a.publicShare, createdAt: clock)
        let b = try RemoteGroupJoinCrypto.session(.responder, code: "123456", candidate: candidate.id, sid: sid, local: member)
        let memberKeys = try b.finish(peerShare: join.share, peerAssociatedData: candidate.associatedData)
        let candidateKeys = try a.finish(peerShare: b.publicShare, peerAssociatedData: member.associatedData)
        XCTAssertTrue(candidateKeys.verifyPeerConfirmation(memberKeys.localConfirmation))
        XCTAssertEqual(try RemoteGroupJoinCrypto.expectedCandidateConfirmation(keys: memberKeys, sid: sid, join: join),
                       candidateKeys.localConfirmation, "组员存下的 Ta 就是新设备会回的那个")

        let wrong = try RemoteGroupJoinCrypto.session(.responder, code: "654321", candidate: candidate.id, sid: sid, local: member)
        let wrongKeys = try wrong.finish(peerShare: join.share, peerAssociatedData: candidate.associatedData)
        let candidateView = try a.finish(peerShare: wrong.publicShare, peerAssociatedData: member.associatedData)
        XCTAssertFalse(candidateView.verifyPeerConfirmation(wrongKeys.localConfirmation))

        // CI 绑着新设备 ID：同一个码、同一个 sid，换一台新设备就对不上。
        let otherCI = try RemoteGroupJoinCrypto.session(.responder, code: "123456", candidate: UUID(), sid: sid, local: member)
        let otherKeys = try otherCI.finish(peerShare: join.share, peerAssociatedData: candidate.associatedData)
        let view = try a.finish(peerShare: otherCI.publicShare, peerAssociatedData: member.associatedData)
        XCTAssertFalse(view.verifyPeerConfirmation(otherKeys.localConfirmation))
    }

    func test_package_is_bound_to_round_and_devices() throws {
        let candidate = device("iPhone"), member = device("Mac")
        let sid = RemoteGroupJoinCrypto.newSessionID()
        let a = try RemoteGroupJoinCrypto.session(.initiator, code: "111111", candidate: candidate.id, sid: sid, local: candidate)
        let b = try RemoteGroupJoinCrypto.session(.responder, code: "111111", candidate: candidate.id, sid: sid, local: member)
        let keys = try b.finish(peerShare: a.publicShare, peerAssociatedData: candidate.associatedData)
        let package = RemoteGroupAdmissionPackage(
            member: RemoteGroupMember(device: member, admission: admission(of: member, by: member)),
            others: [], removals: [], admission: admission(of: candidate, by: member, at: 1))
        let key = RemoteGroupJoinCrypto.packageKey(keys)
        let sealed = try RemoteGroupJoinCrypto.sealPackage(package, key: key, sid: sid, candidate: candidate.id, member: member.id)
        XCTAssertEqual(RemoteGroupJoinCrypto.openPackage(sealed, key: key, sid: sid, candidate: candidate.id, member: member.id),
                       package)
        XCTAssertNil(RemoteGroupJoinCrypto.openPackage(sealed, key: key, sid: RemoteGroupJoinCrypto.newSessionID(),
                                                       candidate: candidate.id, member: member.id))
        XCTAssertNil(RemoteGroupJoinCrypto.openPackage(sealed, key: key, sid: sid, candidate: UUID(), member: member.id))
        XCTAssertNil(RemoteGroupJoinCrypto.openPackage(sealed, key: key, sid: sid, candidate: candidate.id, member: UUID()))
        XCTAssertNil(RemoteGroupJoinCrypto.openPackage(sealed, key: RemoteGroupJoinCrypto.entryKey(keys), sid: sid,
                                                       candidate: candidate.id, member: member.id), "两种用途的钥匙不同")
    }

    // MARK: - 组员名单算法

    /// 同一批记录不论名册里的先后，算出同一份名单：一直在线的与离线很久才回来的设备一致。
    func test_membership_does_not_depend_on_record_order() throws {
        let keys = (0..<4).map { _ in Curve25519.Signing.PrivateKey() }
        let local = device("Local", signing: keys[0])
        let a = device("A", signing: keys[1]), b = device("B", signing: keys[2]), c = device("C", signing: keys[3])
        let t = RemoteGroupTime(clock)
        var state = RemoteGroupLocalState()
        state.selfAdmission = admission(of: local, by: local)
        state.members = [RemoteGroupMember(device: a, admission: admission(of: a, by: local))]
        let admitB = try RemoteGroupAdmit.make(device: b, admission: admission(of: b, by: a, at: 1), signer: a, signedAt: t,
                                               key: keys[1])
        let admitC = try RemoteGroupAdmit.make(device: c, admission: admission(of: c, by: b, at: 2), signer: b,
                                               signedAt: RemoteGroupTime(clock.addingTimeInterval(2)), key: keys[2])
        let removeA = try RemoteGroupRemove.make(target: a, admission: nil, removedAt: RemoteGroupTime(clock.addingTimeInterval(5)), signer: b,
                                                 key: keys[2])
        let orders: [[Int]] = [[0, 1], [1, 0]]
        var results: [Set<String>] = []
        for order in orders {
            var snapshot = RemoteGroupSnapshot()
            let admits = [admitB, admitC]
            snapshot.admits = order.map { admits[$0] }
            snapshot.removes = [removeA]
            let resolved = RemoteGroupMembership.resolve(state, snapshot: snapshot, local: local)
            results.append(Set(resolved.members.map(\.device.name)))
        }
        XCTAssertEqual(results[0], ["B", "C"], "A 加了 B、B 加了 C、B 又移除了 A：剩 B 与 C")
        XCTAssertEqual(results[0], results[1])
    }

    func test_signer_must_have_joined_before_it_signed() throws {
        let localKey = Curve25519.Signing.PrivateKey(), aKey = Curve25519.Signing.PrivateKey()
        let local = device("Local", signing: localKey), a = device("A", signing: aKey), x = device("X")
        var state = RemoteGroupLocalState()
        state.selfAdmission = admission(of: local, by: local)
        state.members = [RemoteGroupMember(device: a, admission: admission(of: a, by: local, at: 100))]
        let early = try RemoteGroupAdmit.make(device: x, admission: admission(of: x, by: a, at: 50), signer: a,
                                              signedAt: RemoteGroupTime(clock.addingTimeInterval(50)), key: aKey)
        var snapshot = RemoteGroupSnapshot(admits: [early])
        XCTAssertTrue(RemoteGroupMembership.resolve(state, snapshot: snapshot, local: local).members.count == 1,
                      "A 进组之前签的 admit 不算")
        let late = try RemoteGroupAdmit.make(device: x, admission: admission(of: x, by: a, at: 50), signer: a,
                                             signedAt: RemoteGroupTime(clock.addingTimeInterval(100)), key: aKey)
        snapshot.admits = [late]
        XCTAssertEqual(RemoteGroupMembership.resolve(state, snapshot: snapshot, local: local).members.count, 2)
    }

    // MARK: - 最初添加者

    func test_original_admission_signature_binds_device_admitter_and_time() {
        let mac = device("Mac"), phone = device("iPhone"), other = device("Other")
        let signed = admission(of: phone, by: mac)
        XCTAssertTrue(signed.isValid(for: phone))
        XCTAssertFalse(signed.isValid(for: other), "搬不到别的设备上")
        var later = signed
        later.admittedAt = later.admittedAt.next
        XCTAssertFalse(later.isValid(for: phone), "改不了加入时间")
        var renamed = signed
        renamed.admitterID = other.id
        renamed.admitterKey = other.signingKey
        XCTAssertFalse(renamed.isValid(for: phone), "改成别的添加者，签名就对不上那把钥匙")
        var rekeyed = phone
        rekeyed.publicKey = other.publicKey
        XCTAssertFalse(signed.isValid(for: rekeyed), "签名也覆盖 X25519")
    }

    func test_admit_is_dropped_unless_the_named_admitter_signed_it() throws {
        let key = Curve25519.Signing.PrivateKey()
        let thief = device("S", signing: key), honest = device("A"), x = device("X")
        // 被偷的组员想把它加的设备记到 A 名下：A 的签名它做不出来，用自己的钥匙签就对不上 A。
        var forged = try RemoteGroupAdmission.make(device: x, admitter: thief, admittedAt: RemoteGroupTime(clock), key: key)
        forged.admitterID = honest.id
        forged.admitterKey = honest.signingKey
        let admit = try RemoteGroupAdmit.make(device: x, admission: forged, signer: thief, signedAt: RemoteGroupTime(clock),
                                              key: key)
        XCTAssertTrue(admit.hasValidSignature, "补签本身是对的")
        XCTAssertNil(try roundTrip(.admit(admit)), "最初添加者的签名对不上，整条不收")
        // 让它自称「第一台」也不收。
        let selfAdmitted = try RemoteGroupAdmit.make(device: x, admission: admission(of: x, by: x), signer: thief,
                                                     signedAt: RemoteGroupTime(clock), key: key)
        XCTAssertNil(try roundTrip(.admit(selfAdmitted)), "名册里不收自己加自己的 admit")
        let honestAdmit = try RemoteGroupAdmit.make(device: x, admission: admission(of: x, by: thief), signer: thief,
                                                    signedAt: RemoteGroupTime(clock), key: key)
        XCTAssertNotNil(try roundTrip(.admit(honestAdmit)), "如实写成自己加的照收")
    }

    func test_admit_naming_an_admitter_the_verifier_never_knew_is_ignored() throws {
        let localKey = Curve25519.Signing.PrivateKey(), sKey = Curve25519.Signing.PrivateKey()
        let local = device("Local", signing: localKey), s = device("S", signing: sKey)
        let fresh = device("K"), x = device("X")
        var state = RemoteGroupLocalState()
        state.selfAdmission = admission(of: local, by: local)
        state.members = [RemoteGroupMember(device: s, admission: admission(of: s, by: local))]
        let viaFresh = try RemoteGroupAdmit.make(device: x, admission: admission(of: x, by: fresh), signer: s,
                                                 signedAt: RemoteGroupTime(clock), key: sKey)
        var snapshot = RemoteGroupSnapshot(admits: [viaFresh])
        XCTAssertEqual(RemoteGroupMembership.resolve(state, snapshot: snapshot, local: local).members.count, 1,
                       "现造的钥匙不是认得的添加者")
        // 自己加自己的「第一台」记在移除记录里也不算认得：只有当过它组员的设备才知道是真的。
        snapshot.removes = [try RemoteGroupRemove.make(target: fresh, admission: admission(of: fresh, by: fresh),
                                                       removedAt: RemoteGroupTime(clock), signer: s, key: sKey)]
        XCTAssertEqual(RemoteGroupMembership.resolve(state, snapshot: snapshot, local: local).members.count, 1)
        // 移除记录里带着「由 S 加的」：认得了，但它连同 X 都在 S 的移除连带链条上（见 RemoteDeviceGroupTests）。
        snapshot.removes = [try RemoteGroupRemove.make(target: fresh, admission: admission(of: fresh, by: s),
                                                       removedAt: RemoteGroupTime(clock), signer: s, key: sKey)]
        let resolved = RemoteGroupMembership.resolve(state, snapshot: snapshot, local: local)
        XCTAssertEqual(Set(resolved.members.map(\.device.name)), ["S", "X"])
        XCTAssertEqual(resolved.removals.first?.admission?.admitterKey, s.signingKey)
    }

    // MARK: - 本机存储

    func test_local_state_read_failure_is_not_treated_as_empty() {
        let store = RemoteGroupLocalStore(storage: FailingSecretStorage())
        XCTAssertThrowsError(try store.state(), "读不出来要报错，不能当成空的再写回去把名单清掉")
    }
}

/// 读写都失败的钥匙串（锁着、不可用）。
nonisolated final class FailingSecretStorage: RemoteSecretStorage, @unchecked Sendable {
    struct Unavailable: Error {}

    func load(_ account: String) throws -> Data? { throw Unavailable() }
    func save(_ data: Data, account: String) throws { throw Unavailable() }
    func delete(_ account: String) throws { throw Unavailable() }
}
