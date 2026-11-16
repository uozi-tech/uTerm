import CryptoKit
import Foundation
import XCTest
@testable import uTerm

/// 「我的设备」：名册记录、先承诺后揭示的 6 位核对码、两台设备走完一次确认，以及冒充者能做到什么、做不到什么。
@MainActor
final class RemoteSiblingTests: XCTestCase {
    // XCTest 每个用例建一个新实例，所以每个用例各有一份名册。
    private let syncedStorage = RemoteMemorySyncedStorage()
    private lazy var roster = RemoteSiblingRoster(storage: syncedStorage)
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    private func device(_ name: String, platform: RemoteDevicePlatform = .mobile, key: Data? = nil) -> RemoteSiblingDevice {
        RemoteSiblingDevice(id: UUID(), name: name, model: nil, platform: platform.rawValue,
                            publicKey: key ?? Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
                            updatedAt: clock)
    }

    private func model(_ local: RemoteSiblingDevice, store: RemoteSiblingLocalStore? = nil) -> RemoteSiblingDevices {
        RemoteSiblingDevices(local: local, roster: roster, store: store ?? RemoteSiblingLocalStore(storage: RemoteMemoryStorage()),
                             now: { [unowned self] in self.clock })
    }

    /// 走到新设备显示数字、已有设备等你输入为止，返回新设备上显示的数（你要抄到已有设备上的那个）。
    private func runUntilEntering(voucher: RemoteSiblingDevices, candidate: RemoteSiblingDevices,
                                  file: StaticString = #filePath, line: UInt = #line) -> String {
        voucher.refresh()
        candidate.refresh()
        voucher.confirm(candidate.localDevice.id)
        candidate.refresh()
        voucher.refresh()
        guard case .entering = voucher.confirmation, let code = candidate.incoming.first?.code else {
            XCTFail("已有设备应当等着输入：\(String(describing: voucher.confirmation))", file: file, line: line)
            return ""
        }
        return code
    }

    // MARK: - 记录与核对码

    func test_roster_uses_its_own_service_not_the_deleted_legacy_one() {
        XCTAssertNotEqual(RemoteSiblingRoster.service, RemoteLegacyRoster.service,
                          "旧测试版还会凭 com.uozi.uTerm.remote.roster 放行，新名册不能写进去")
    }

    func test_records_round_trip_and_bad_ones_are_dropped() throws {
        let phone = device("iPhone")
        XCTAssertEqual(RemoteSiblingRecord.decode(try RemoteSiblingRecord.device(phone).encoded()), .device(phone))

        var short = phone
        short.publicKey = Data(repeating: 1, count: 31)
        XCTAssertNil(RemoteSiblingRecord.decode(try RemoteSiblingRecord.device(short).encoded()), "钥匙长度不对的不认")
        XCTAssertNil(RemoteSiblingRecord.decode(Data(#"{"v":2,"record":"device"}"#.utf8)), "不认识的版本跳过")
        XCTAssertNil(RemoteSiblingRecord.decode(Data(#"{"v":1,"record":"grant"}"#.utf8)), "不认识的记录跳过")
        XCTAssertNil(RemoteSiblingRecord.decode(Data("garbage".utf8)))
    }

    func test_code_binds_both_devices_and_both_nonces() {
        let phone = device("iPhone"), pad = device("iPad")
        let rn = RemoteSiblingCode.newNonce(), ro = RemoteSiblingCode.newNonce()
        let code = RemoteSiblingCode.code(candidate: pad, voucher: phone, candidateNonce: rn, voucherNonce: ro)
        XCTAssertEqual(code.count, 6)
        XCTAssertEqual(code, RemoteSiblingCode.code(candidate: pad, voucher: phone, candidateNonce: rn, voucherNonce: ro))
        // 换掉任何一样，绝大多数情况下数都会变（取几个固定输入，避免百万分之一的偶然碰撞让用例忽红忽绿）。
        let other = device("Other")
        let variants = [
            RemoteSiblingCode.code(candidate: other, voucher: phone, candidateNonce: rn, voucherNonce: ro),
            RemoteSiblingCode.code(candidate: pad, voucher: other, candidateNonce: rn, voucherNonce: ro),
            RemoteSiblingCode.code(candidate: pad, voucher: phone, candidateNonce: RemoteSiblingCode.newNonce(), voucherNonce: ro),
            RemoteSiblingCode.code(candidate: pad, voucher: phone, candidateNonce: rn, voucherNonce: RemoteSiblingCode.newNonce()),
        ]
        XCTAssertGreaterThanOrEqual(variants.filter { $0 != code }.count, 3)
        XCTAssertNotEqual(RemoteSiblingCode.commitment(candidate: pad, voucher: phone, nonce: rn),
                          RemoteSiblingCode.commitment(candidate: pad, voucher: phone, nonce: ro))
    }

    // MARK: - 正常确认

    func test_two_devices_list_each_other_and_complete_a_confirmation() throws {
        let phone = model(device("iPhone"))
        let pad = model(device("iPad"))
        phone.refresh()
        pad.refresh()
        phone.refresh()
        XCTAssertEqual(phone.rows.map(\.device.name), ["iPad"])
        XCTAssertEqual(pad.rows.map(\.device.name), ["iPhone"])
        XCTAssertEqual(phone.rows.first?.status, .unconfirmed)
        XCTAssertNotNil(roster.load().message(.commitment, candidate: pad.localDevice.id, voucher: phone.localDevice.id),
                        "新设备先承诺")

        phone.confirm(pad.localDevice.id)
        XCTAssertEqual(phone.confirmation, .waiting(pad.localDevice))
        XCTAssertNotNil(roster.load().message(.challenge, candidate: pad.localDevice.id, voucher: phone.localDevice.id))

        pad.refresh()
        let shown = try XCTUnwrap(pad.incoming.first, "新设备看到确认就显示数字")
        XCTAssertEqual(shown.voucher.id, phone.localDevice.id)

        phone.refresh()
        XCTAssertEqual(phone.confirmation, .entering(pad.localDevice, attemptsLeft: RemoteSiblingDevices.codeAttempts),
                       "已有设备不显示数，等你从新设备上抄过来")

        XCTAssertTrue(phone.submitCode(String(shown.code.prefix(3)) + " " + String(shown.code.suffix(3))), "空格不算")
        XCTAssertNil(phone.confirmation)
        guard case .confirmed = phone.rows.first?.status else { return XCTFail("确认后记下：\(phone.rows)") }

        // 新设备那边拒绝（或允许）之后清掉这一次的记录。
        pad.dismissIncoming(phone.localDevice.id)
        XCTAssertTrue(pad.incoming.isEmpty)
        let after = roster.load()
        XCTAssertNil(after.message(.challenge, candidate: pad.localDevice.id, voucher: phone.localDevice.id))
        XCTAssertNil(after.message(.reveal, candidate: pad.localDevice.id, voucher: phone.localDevice.id))
        XCTAssertEqual(pad.rows.first?.status, .unconfirmed, "确认是单向的：iPad 没确认过 iPhone")
    }

    func test_confirmation_is_only_stored_on_the_device_that_confirmed() throws {
        let phoneStore = RemoteSiblingLocalStore(storage: RemoteMemoryStorage())
        let phone = model(device("iPhone"), store: phoneStore)
        let pad = model(device("iPad"))
        XCTAssertTrue(phone.submitCode(runUntilEntering(voucher: phone, candidate: pad)))
        XCTAssertNotNil(phoneStore.approvals()[pad.localDevice.id])
        for data in syncedStorage.loadAll() {
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("approvedAt"), "同步的名册里没有确认结果")
        }
    }

    func test_cancel_records_nothing() {
        let phone = model(device("iPhone"))
        let pad = model(device("iPad"))
        _ = runUntilEntering(voucher: phone, candidate: pad)
        phone.cancel()
        XCTAssertNil(phone.confirmation)
        XCTAssertEqual(phone.rows.first?.status, .unconfirmed)
        pad.refresh()
        XCTAssertTrue(pad.incoming.isEmpty)
    }

    func test_wrong_code_uses_up_attempts_then_stops_and_records_nothing() {
        let phone = model(device("iPhone"))
        let pad = model(device("iPad"))
        let code = runUntilEntering(voucher: phone, candidate: pad)
        let wrong = code == "000000" ? "111111" : "000000"
        XCTAssertFalse(phone.submitCode(wrong))
        XCTAssertEqual(phone.confirmation, .entering(pad.localDevice, attemptsLeft: RemoteSiblingDevices.codeAttempts - 1))
        for _ in 1..<RemoteSiblingDevices.codeAttempts { XCTAssertFalse(phone.submitCode(wrong)) }
        guard case .failed = phone.confirmation else { return XCTFail("输错用完应当停止：\(String(describing: phone.confirmation))") }
        XCTAssertFalse(phone.submitCode(code), "停了之后输对也不算")
        XCTAssertEqual(phone.rows.first?.status, .unconfirmed)
        XCTAssertNil(roster.load().message(.challenge, candidate: pad.localDevice.id, voucher: phone.localDevice.id))
    }

    func test_candidate_keeps_showing_the_same_code_after_a_restart_and_does_not_answer_twice() throws {
        let padStore = RemoteSiblingLocalStore(storage: RemoteMemoryStorage())
        let padDevice = device("iPad")
        let phone = model(device("iPhone"))
        var pad = model(padDevice, store: padStore)
        phone.refresh()
        pad.refresh()
        phone.confirm(padDevice.id)
        pad.refresh()
        let first = try XCTUnwrap(pad.incoming.first?.code)
        let reveal = roster.load().message(.reveal, candidate: padDevice.id, voucher: phone.localDevice.id)

        pad = model(padDevice, store: padStore)
        pad.refresh()
        XCTAssertEqual(pad.incoming.first?.code, first)
        XCTAssertEqual(roster.load().message(.reveal, candidate: padDevice.id, voucher: phone.localDevice.id), reveal,
                       "同一次确认只答一次")
        phone.refresh()
        XCTAssertTrue(phone.submitCode(first), "重开后显示的数仍然是这一次的")
    }

    func test_commitment_is_renewed_after_answering() throws {
        let phone = model(device("iPhone"))
        let pad = model(device("iPad"))
        phone.refresh()
        pad.refresh()
        let before = try XCTUnwrap(roster.load().message(.commitment, candidate: pad.localDevice.id, voucher: phone.localDevice.id))
        phone.confirm(pad.localDevice.id)
        pad.refresh()
        let after = try XCTUnwrap(roster.load().message(.commitment, candidate: pad.localDevice.id, voucher: phone.localDevice.id))
        XCTAssertNotEqual(before.value, after.value, "答出去的随机数作废，下一次确认用新的承诺")
    }

    // MARK: - 冒充

    func test_reveal_that_does_not_match_the_commitment_stops_the_confirmation() throws {
        let phone = model(device("iPhone"))
        let pad = model(device("iPad"))
        phone.refresh()
        pad.refresh()
        phone.confirm(pad.localDevice.id)
        // 冒充者抢先答：它看得到 challenge 里的随机数，但事先的承诺不是它做的。
        let challenge = try XCTUnwrap(roster.load().message(.challenge, candidate: pad.localDevice.id, voucher: phone.localDevice.id))
        let forged = RemoteSiblingMessage(kind: .reveal, candidate: pad.localDevice.id, candidateKey: pad.localDevice.publicKey,
                                          voucher: phone.localDevice.id, voucherKey: phone.localDevice.publicKey,
                                          value: RemoteSiblingCode.newNonce() + challenge.value, createdAt: clock)
        try roster.save(.message(forged))
        phone.refresh()
        guard case .failed = phone.confirmation else { return XCTFail("应当停止：\(String(describing: phone.confirmation))") }
        phone.cancel()
        XCTAssertEqual(phone.rows.first?.status, .unconfirmed)
    }

    func test_a_reveal_answering_another_challenge_is_ignored() throws {
        let phone = model(device("iPhone"))
        let pad = model(device("iPad"))
        phone.refresh()
        pad.refresh()
        phone.confirm(pad.localDevice.id)
        let stale = RemoteSiblingMessage(kind: .reveal, candidate: pad.localDevice.id, candidateKey: pad.localDevice.publicKey,
                                         voucher: phone.localDevice.id, voucherKey: phone.localDevice.publicKey,
                                         value: RemoteSiblingCode.newNonce() + RemoteSiblingCode.newNonce(), createdAt: clock)
        try roster.save(.message(stale))
        phone.refresh()
        XCTAssertEqual(phone.confirmation, .waiting(pad.localDevice), "上一次留下的、答别的随机数的 reveal 不算")
    }

    func test_impostor_entry_cannot_make_the_real_device_show_its_code() {
        let phone = model(device("iPhone"))
        let pad = model(device("iPad"))
        // 钥匙串圈里的冒充者也登记一台「iPad」，自己承诺、自己回答。
        let impostor = model(device("iPad"))
        phone.refresh()
        pad.refresh()
        impostor.refresh()
        phone.refresh()
        XCTAssertEqual(phone.rows.count, 2, "名字一样也是两台，各自确认")

        phone.confirm(impostor.localDevice.id)
        impostor.refresh()
        pad.refresh()
        phone.refresh()
        guard case .entering = phone.confirmation else { return XCTFail("冒充者照样能答到这一步") }
        XCTAssertTrue(pad.incoming.isEmpty, "真 iPad 上什么数都不显示：你没有数可抄，输不对")
    }

    func test_forged_challenge_only_makes_the_candidate_show_a_code() throws {
        let phone = model(device("iPhone"))
        let pad = model(device("iPad"))
        phone.refresh()
        pad.refresh()
        let forged = RemoteSiblingMessage(kind: .challenge, candidate: pad.localDevice.id, candidateKey: pad.localDevice.publicKey,
                                          voucher: phone.localDevice.id, voucherKey: phone.localDevice.publicKey,
                                          value: RemoteSiblingCode.newNonce(), createdAt: clock)
        try roster.save(.message(forged))
        pad.refresh()
        XCTAssertEqual(pad.incoming.count, 1)
        phone.refresh()
        XCTAssertNil(phone.confirmation, "iPhone 没在确认，什么也不会记")
        XCTAssertEqual(phone.rows.first?.status, .unconfirmed)
    }

    func test_challenge_for_another_key_is_not_answered() throws {
        let phone = model(device("iPhone"))
        let pad = model(device("iPad"))
        phone.refresh()
        pad.refresh()
        let forged = RemoteSiblingMessage(kind: .challenge, candidate: pad.localDevice.id,
                                          candidateKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
                                          voucher: phone.localDevice.id, voucherKey: phone.localDevice.publicKey,
                                          value: RemoteSiblingCode.newNonce(), createdAt: clock)
        try roster.save(.message(forged))
        pad.refresh()
        XCTAssertTrue(pad.incoming.isEmpty)
        XCTAssertNil(roster.load().message(.reveal, candidate: pad.localDevice.id, voucher: phone.localDevice.id))
    }

    // MARK: - 换钥匙、移除、超时、残留

    func test_device_that_changed_its_key_needs_confirming_again() {
        let phone = model(device("iPhone"))
        let padDevice = device("iPad")
        let pad = model(padDevice)
        XCTAssertTrue(phone.submitCode(runUntilEntering(voucher: phone, candidate: pad)))

        var reinstalled = padDevice
        reinstalled.publicKey = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        model(reinstalled).refresh()
        phone.refresh()
        XCTAssertEqual(phone.rows.first?.status, .keyChanged)
        XCTAssertTrue(phone.rows.first?.needsConfirmation ?? false)
    }

    func test_confirmation_stops_when_the_device_changes_its_key_midway() {
        let phone = model(device("iPhone"))
        let padDevice = device("iPad")
        let pad = model(padDevice)
        phone.refresh()
        pad.refresh()
        phone.confirm(padDevice.id)
        var reinstalled = padDevice
        reinstalled.publicKey = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        model(reinstalled).refresh()
        phone.refresh()
        guard case .failed = phone.confirmation else { return XCTFail("\(String(describing: phone.confirmation))") }
    }

    func test_removed_device_disappears_with_its_messages_and_comes_back_when_it_registers_again() {
        let phone = model(device("iPhone"))
        let pad = model(device("iPad"))
        XCTAssertTrue(phone.submitCode(runUntilEntering(voucher: phone, candidate: pad)))
        phone.remove(pad.localDevice.id)
        XCTAssertTrue(phone.rows.isEmpty)
        XCTAssertFalse(roster.load().messages.contains { $0.candidate == pad.localDevice.id || $0.voucher == pad.localDevice.id })

        pad.refresh()
        phone.refresh()
        XCTAssertEqual(phone.rows.first?.status, .unconfirmed, "重新出现要重新确认")
    }

    func test_waiting_times_out() {
        let phone = model(device("iPhone"))
        let pad = model(device("iPad"))
        phone.refresh()
        pad.refresh()
        phone.confirm(pad.localDevice.id)
        clock += RemoteSiblingDevices.confirmationTimeout + 1
        phone.refresh()
        guard case .failed = phone.confirmation else { return XCTFail("\(String(describing: phone.confirmation))") }
        XCTAssertNil(roster.load().message(.challenge, candidate: pad.localDevice.id, voucher: phone.localDevice.id))
    }

    func test_waits_for_the_candidate_to_commit_first() {
        let phone = model(device("iPhone"))
        // iPad 登记过，但还没打开过「我的设备」：没有承诺。
        let padDevice = device("iPad")
        try? roster.save(.device(padDevice))
        phone.refresh()
        phone.confirm(padDevice.id)
        XCTAssertEqual(phone.confirmation, .waiting(padDevice))
        XCTAssertNil(roster.load().message(.challenge, candidate: padDevice.id, voucher: phone.localDevice.id),
                     "对方没承诺之前不出随机数")
        let pad = model(padDevice)
        pad.refresh()
        phone.refresh()
        XCTAssertNotNil(roster.load().message(.challenge, candidate: padDevice.id, voucher: phone.localDevice.id))
    }

    func test_stale_challenges_from_a_previous_run_are_cleared() {
        let phoneDevice = device("iPhone")
        let phone = model(phoneDevice)
        let pad = model(device("iPad"))
        phone.refresh()
        pad.refresh()
        phone.confirm(pad.localDevice.id)
        XCTAssertNotNil(roster.load().message(.challenge, candidate: pad.localDevice.id, voucher: phoneDevice.id))
        // App 重开：随机数只在内存里，接不上，清掉。
        model(phoneDevice).refresh()
        XCTAssertNil(roster.load().message(.challenge, candidate: pad.localDevice.id, voucher: phoneDevice.id))
    }

    func test_registration_rewrites_only_when_something_changed() throws {
        let phone = device("iPhone")
        try roster.register(phone, existing: nil)
        var later = phone
        later.updatedAt = clock + 3600
        try roster.register(later, existing: roster.load().device(phone.id))
        XCTAssertEqual(roster.load().device(phone.id)?.updatedAt, phone.updatedAt, "只换时间不重写")
        later.name = "新名字"
        try roster.register(later, existing: roster.load().device(phone.id))
        XCTAssertEqual(roster.load().device(phone.id)?.name, "新名字")
    }

    // MARK: - 本机身份

    func test_existing_identity_never_generates_one() throws {
        let identity = RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage())
        XCTAssertNil(identity.existingIdentity())
        XCTAssertThrowsError(try RemoteSiblingDevice.local(name: "x", model: nil, identity: identity, createsIdentity: false))
        XCTAssertNil(identity.existingIdentity(), "只读不生成")
        let key = try identity.localIdentity()
        XCTAssertEqual(identity.existingIdentity()?.rawRepresentation, key.rawRepresentation)
    }
}
