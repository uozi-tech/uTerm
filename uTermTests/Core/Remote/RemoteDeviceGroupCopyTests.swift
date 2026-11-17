import CryptoKit
import XCTest
@testable import uTerm

/// 「我的设备」两端共用的、不依赖视图的部分：随状态变的文案、移除时连带设备的默认勾选、旧数据的清理。
@MainActor
final class RemoteDeviceGroupCopyTests: XCTestCase {
    private func device(_ name: String, model: String? = nil) -> RemoteGroupDevice {
        RemoteGroupDevice(id: UUID(), name: name, model: model, platform: RemoteDevicePlatform.mobile.rawValue,
                          publicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
                          signingKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation, updatedAt: Date())
    }

    // MARK: - 移除连带

    func test_removal_ticks_every_cascaded_device_by_default_and_allows_unticking() {
        let target = device("iPhone"), pad = device("iPad"), mini = device("Mac mini")
        var plan = RemoteGroupRemovalPlan(target: target, cascade: [pad, mini])
        XCTAssertEqual(plan.ids, [target.id, pad.id, mini.id], "默认一起移除")
        XCTAssertTrue(plan.includes(pad.id))

        plan.set(pad.id, included: false)
        XCTAssertEqual(plan.ids, [target.id, mini.id])
        XCTAssertFalse(plan.includes(pad.id))
        plan.set(pad.id, included: true)
        XCTAssertEqual(plan.ids, [target.id, pad.id, mini.id], "按列表顺序")

        // 不在连带里的设备勾不进来；要移除的那台自己不算连带。
        plan.set(UUID(), included: true)
        XCTAssertEqual(plan.ids.count, 3)
        let selfListed = RemoteGroupRemovalPlan(target: target, cascade: [target, pad])
        XCTAssertEqual(selfListed.cascade, [pad])
        XCTAssertEqual(selfListed.ids, [target.id, pad.id])
        XCTAssertEqual(RemoteGroupRemovalPlan(target: target, cascade: []).ids, [target.id])
    }

    // MARK: - 被移出后的设备列表

    func test_removed_device_still_lists_its_former_group() throws {
        let roster = RemoteGroupRoster(storage: RemoteMemorySyncedStorage())
        func make(_ name: String) -> RemoteDeviceGroup {
            let store = RemoteGroupLocalStore(storage: RemoteMemoryStorage())
            let key = try! store.signingKey()
            return RemoteDeviceGroup(local: RemoteGroupDevice(id: UUID(), name: name, model: nil, platform: "mobile",
                                                              publicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
                                                              signingKey: key.publicKey.rawRepresentation, updatedAt: Date()),
                                     signingKey: key, roster: roster, store: store)
        }
        let phone = make("iPhone"), pad = make("iPad")
        phone.refresh()
        pad.startJoin()
        phone.refresh()
        guard case .showingCode(let code, _) = pad.joinState else { return XCTFail("没显示核对码") }
        XCTAssertTrue(phone.submitCode(code, for: pad.local.id))
        pad.refresh()
        phone.refresh()
        pad.refresh()
        XCTAssertTrue(pad.isInGroup)
        XCTAssertEqual(pad.listedOtherDevices, pad.otherDevices, "在组里时就是名册里不在组里的那些")

        phone.remove([pad.local.id])
        pad.refresh()
        XCTAssertTrue(pad.isSelfRemoved)
        XCTAssertEqual(pad.listedOtherDevices.map(\.id), [phone.local.id], "被移出后原来组里的设备照样列出来")
    }

    // MARK: - 文案

    func test_code_caption_says_when_the_code_was_replaced() {
        let fresh = RemoteDeviceGroupCopy.codeCaption(attemptsLeft: RemoteDeviceGroup.codeAttempts)
        let replaced = RemoteDeviceGroupCopy.codeCaption(attemptsLeft: RemoteDeviceGroup.codeAttempts - 1)
        XCTAssertNotEqual(fresh, replaced)
        XCTAssertTrue(replaced.contains("\(RemoteDeviceGroup.codeAttempts - 1)"), replaced)
    }

    func test_member_subtitle_lists_model_this_device_and_admitter() {
        let mine = device("我的 MacBook", model: "MacBook Pro")
        let local = RemoteDeviceGroup.MemberRow(device: mine, isLocal: true, admittedByName: "iPhone")
        XCTAssertEqual(RemoteDeviceGroupCopy.memberSubtitle(local),
                       ["MacBook Pro", RemoteDeviceGroupCopy.thisDevice, "由「iPhone」添加"].joined(separator: " · "))
        // 名字就是机型：不重复；第一台没有添加者。
        let first = RemoteDeviceGroup.MemberRow(device: device("iPad", model: "iPad"), isLocal: false, admittedByName: nil)
        XCTAssertNil(RemoteDeviceGroupCopy.memberSubtitle(first))
    }

    func test_request_states_decide_input_and_warning() {
        let pad = device("iPad")
        let statuses: [RemoteDeviceGroup.JoinRequest.Status] = [
            .waitingForCode(attemptsLeft: 3), .verifying, .wrongCode(attemptsLeft: 2), .limitReached, .admitted,
        ]
        XCTAssertEqual(statuses.map(RemoteDeviceGroupCopy.acceptsCode), [true, false, true, false, false])
        XCTAssertEqual(statuses.map(RemoteDeviceGroupCopy.isWarning), [false, false, true, true, false])
        let details = statuses.map { RemoteDeviceGroupCopy.requestDetail(.init(candidate: pad, status: $0)) }
        XCTAssertEqual(Set(details).count, statuses.count, "每个状态各有一句")
        XCTAssertTrue(details[2].contains("iPad") && details[2].contains("2"), details[2])
    }

    // MARK: - 旧数据

    func test_retiring_legacy_data_clears_the_old_roster_and_local_accounts_only() throws {
        let synced = RemoteMemorySyncedStorage()
        try synced.save(Data([1]), account: "device.x")
        try synced.save(Data([2]), account: "message.y")
        let secrets = RemoteMemoryStorage()
        for account in RemoteLegacyDevices.localAccounts { try secrets.save(Data([3]), account: account) }
        try secrets.save(Data([4]), account: "identity")
        try secrets.save(Data([5]), account: RemoteGroupLocalStore.stateAccount)

        RemoteLegacyDevices.retire(synced: synced, secrets: secrets)
        XCTAssertTrue(synced.loadAll().isEmpty)
        for account in RemoteLegacyDevices.localAccounts { XCTAssertNil(try secrets.load(account)) }
        XCTAssertEqual(try secrets.load("identity"), Data([4]), "远控身份不动")
        XCTAssertEqual(try secrets.load(RemoteGroupLocalStore.stateAccount), Data([5]), "设备组的状态不动")

        // 再来一遍什么都没有，也不出错。
        RemoteLegacyDevices.retire(synced: synced, secrets: secrets)
        XCTAssertNotEqual(RemoteLegacyDevices.service, RemoteGroupRoster.service)
    }

    func test_removed_device_status_names_the_last_mac_and_counts_otherwise() {
        func row(_ hosts: [String]) -> RemoteDeviceGroup.RemovedDevice {
            RemoteDeviceGroup.RemovedDevice(id: Data([1]), deviceID: UUID(), name: "iPad", waitingHosts: hosts)
        }
        XCTAssertEqual(RemoteDeviceGroupCopy.removedStatus(row(["Mac mini"])), "「Mac mini」尚未撤销")
        XCTAssertEqual(RemoteDeviceGroupCopy.removedStatus(row(["Mac mini", "iMac"])), "2 台 Mac 尚未撤销")
    }

    /// G3 给本机状态加了两个字段：老版本存下的状态（没有这两个键）照样解得开，不当成空的（当成空的会清掉组员名单）。
    func test_local_state_saved_before_g3_still_decodes() throws {
        var state = RemoteGroupLocalState()
        state.selfRemoved = true
        state.submissions = [UUID(): [Date(timeIntervalSince1970: 1)]]
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: RemoteGroupFormat.encoder().encode(state))
            as? [String: Any])
        object["revocations"] = nil
        object["adoptedHosts"] = nil
        let old = try JSONSerialization.data(withJSONObject: object)
        let decoded = try RemoteGroupFormat.decoder().decode(RemoteGroupLocalState.self, from: old)
        XCTAssertEqual(decoded, state)
        XCTAssertTrue(decoded.revocations.isEmpty)
    }
}
