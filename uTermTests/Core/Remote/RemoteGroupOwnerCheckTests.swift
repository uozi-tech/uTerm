import CryptoKit
import LocalAuthentication
import XCTest
@testable import uTerm

/// 按次序回结果的假验证（§19）：记下每次弹了什么说明。结果用完了就一直回最后一个。
@MainActor
final class RemoteGroupFakeAuthenticator: BiometricAuthenticator {
    var outcomes: [AuthOutcome]
    private(set) var reasons: [String] = []
    private(set) var policies: [LAPolicy] = []
    /// 设了就在这里等，测「同时来两次只弹一个框」。
    var gate: CheckedContinuation<Void, Never>?
    var holds = false

    init(_ outcomes: AuthOutcome...) {
        self.outcomes = outcomes
    }

    var calls: Int { reasons.count }

    func availability() -> BiometryAvailability { .biometrics }

    func authenticate(policy: LAPolicy, reason: String) async -> AuthOutcome {
        reasons.append(reason)
        policies.append(policy)
        if holds { await withCheckedContinuation { gate = $0 } }
        return outcomes.count > 1 ? outcomes.removeFirst() : (outcomes.first ?? .success)
    }

    func release() {
        holds = false
        gate?.resume()
        gate = nil
    }
}

/// 操作前验证本人的规则：通过后 5 分钟内免验、不可用放行、取消 / 失败 / 锁定不放行、测试宿主里默认放行。
@MainActor
final class RemoteGroupOwnerCheckTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    private func check(_ fake: RemoteGroupFakeAuthenticator) -> RemoteGroupOwnerCheck {
        RemoteGroupOwnerCheck(authenticator: fake, now: { [unowned self] in clock })
    }

    func test_success_passes_and_is_not_asked_again_for_five_minutes() async {
        let fake = RemoteGroupFakeAuthenticator(.success)
        let check = check(fake)
        let first = await check.confirm(.leave)
        XCTAssertTrue(first)
        XCTAssertEqual(fake.calls, 1)
        XCTAssertEqual(fake.policies, [.deviceOwnerAuthentication], "生物识别不行退密码")

        clock += RemoteGroupOwnerCheck.gracePeriod - 1
        let within = await check.confirm(.remove(name: "iPad", count: 2))
        XCTAssertTrue(within)
        XCTAssertEqual(fake.calls, 1, "5 分钟内不再验")

        clock += 1
        let after = await check.confirm(.admit(name: "iPad"))
        XCTAssertTrue(after)
        XCTAssertEqual(fake.calls, 2, "过了 5 分钟再验")

        // 钟往回拨了：不算刚验过。
        clock -= 60
        _ = await check.confirm(.leave)
        XCTAssertEqual(fake.calls, 3)
    }

    func test_unavailable_passes_without_counting_as_verified() async {
        let fake = RemoteGroupFakeAuthenticator(.unavailable)
        let check = check(fake)
        let first = await check.confirm(.leave)
        XCTAssertTrue(first, "没有可验证的东西：不能把人锁在外面")
        XCTAssertNil(check.lastVerified)
        _ = await check.confirm(.leave)
        XCTAssertEqual(fake.calls, 2, "不可用不算验过，下次照样问")
    }

    func test_cancel_failure_and_lockout_are_refused() async {
        for outcome in [AuthOutcome.canceled, .failed, .biometryLockout] {
            let fake = RemoteGroupFakeAuthenticator(outcome)
            let check = check(fake)
            let passed = await check.confirm(.remove(name: "iPad", count: 1))
            XCTAssertFalse(passed, "\(outcome)")
            XCTAssertNil(check.lastVerified)
            XCTAssertFalse(check.isFresh)
        }
        // 没过之后再试一次，过了就放行。
        let fake = RemoteGroupFakeAuthenticator(.canceled, .success)
        let check = check(fake)
        let refused = await check.confirm(.leave)
        let retried = await check.confirm(.leave)
        XCTAssertFalse(refused)
        XCTAssertTrue(retried)
        XCTAssertEqual(fake.calls, 2)
    }

    func test_test_host_passes_by_default_without_any_prompt() async {
        XCTAssertTrue(RemoteLocalState.isIsolated)
        XCTAssertNil(RemoteGroupOwnerCheck.defaultAuthenticator(), "测试宿主里不弹系统验证框")
        let check = RemoteGroupOwnerCheck()
        let passed = await check.confirm(.leave)
        XCTAssertTrue(passed)
    }

    func test_two_requests_at_once_show_a_single_prompt() async {
        let fake = RemoteGroupFakeAuthenticator(.success)
        fake.holds = true
        let check = check(fake)
        let first = Task { await check.confirm(.remove(name: "iPad", count: 1)) }
        let second = Task { await check.confirm(.remove(name: "iPad", count: 1)) }
        while fake.gate == nil { await Task.yield() }
        fake.release()
        let results = await [first.value, second.value]
        XCTAssertEqual(results, [true, true])
        XCTAssertEqual(fake.calls, 1, "第二次等第一次的结果，验过了就不再弹")
    }

    func test_reasons_name_the_action() {
        XCTAssertEqual(RemoteGroupOwnerCheck.Action.remove(name: "iPad", count: 1).reason, "移除「iPad」")
        XCTAssertEqual(RemoteGroupOwnerCheck.Action.remove(name: "iPad", count: 3).reason, "移除「iPad」等 3 台设备")
        XCTAssertEqual(RemoteGroupOwnerCheck.Action.admit(name: "iPad").reason, "将「iPad」加入设备组")
        XCTAssertEqual(RemoteGroupOwnerCheck.Action.leave.reason, "离开设备组")
    }
}

/// 服务上带验证的入口：验证没过时什么都不改；过了照常；一次移除（含连带）只验一次。
@MainActor
final class RemoteDeviceGroupServiceOwnerCheckTests: XCTestCase {
    private let synced = RemoteMemorySyncedStorage()
    private lazy var roster = RemoteGroupRoster(storage: synced)

    private func makeDevice(_ name: String) -> RemoteDeviceGroup {
        let store = RemoteGroupLocalStore(storage: RemoteMemoryStorage())
        let key = try! store.signingKey()
        let local = RemoteGroupDevice(id: UUID(), name: name, model: nil, platform: RemoteDevicePlatform.mobile.rawValue,
                                      publicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
                                      signingKey: key.publicKey.rawRepresentation, updatedAt: Date())
        return RemoteDeviceGroup(local: local, signingKey: key, roster: roster, store: store)
    }

    private func join(_ candidate: RemoteDeviceGroup, via member: RemoteDeviceGroup) throws {
        candidate.startJoin()
        member.refresh()
        guard case .showingCode(let code, _) = candidate.joinState else { throw XCTSkip("没显示核对码") }
        XCTAssertTrue(member.submitCode(code, for: candidate.local.id))
        candidate.refresh()
        member.refresh()
        candidate.refresh()
        member.refresh()
        XCTAssertEqual(candidate.joinState, .joined)
    }

    private func service(_ model: RemoteDeviceGroup, _ fake: RemoteGroupFakeAuthenticator) -> RemoteDeviceGroupService {
        let service = RemoteDeviceGroupService(makeModel: { _ in model }, makeFastChannel: { _, _ in nil },
                                               ownerCheck: RemoteGroupOwnerCheck(authenticator: fake))
        service.tick()
        return service
    }

    func test_refused_check_changes_nothing() async throws {
        let phone = makeDevice("iPhone"), pad = makeDevice("iPad"), mini = makeDevice("Mac mini")
        phone.refresh()
        try join(pad, via: phone)
        let fake = RemoteGroupFakeAuthenticator(.canceled)
        let service = service(phone, fake)
        let members = phone.members
        let before = roster.load()

        let removed = await service.remove([pad.local.id])
        XCTAssertFalse(removed)
        let left = await service.leave()
        XCTAssertFalse(left)
        XCTAssertEqual(phone.members, members, "名单不变")
        XCTAssertEqual(roster.load().removes, before.removes, "名册里没有新的移除记录")
        XCTAssertEqual(roster.load().admits, before.admits)
        XCTAssertEqual(fake.reasons, ["移除「iPad」", "离开设备组"])

        // 别的设备想加入：输满了也不核对，请求还在等输码。
        mini.startJoin()
        service.tick()
        let request = try XCTUnwrap(service.pendingRequest)
        guard case .showingCode(let code, _) = mini.joinState else { return XCTFail("没显示核对码") }
        let submitted = await service.submit(code, for: request)
        XCTAssertFalse(submitted)
        XCTAssertTrue(roster.load().answers.isEmpty, "没回 answer")
        XCTAssertEqual(service.pendingRequest?.status, .waitingForCode(attemptsLeft: RemoteDeviceGroup.submissionLimit),
                       "不算一次输码，弹窗不关")
        XCTAssertEqual(fake.reasons.last, "将「Mac mini」加入设备组")

        // 格式不对的不弹验证框。
        let malformed = await service.submit("12", for: request)
        XCTAssertFalse(malformed)
        XCTAssertEqual(fake.calls, 3)
    }

    func test_passed_check_acts_and_a_cascaded_removal_asks_once() async throws {
        let phone = makeDevice("iPhone"), pad = makeDevice("iPad"), laptop = makeDevice("MacBook"), mini = makeDevice("Mac mini")
        phone.refresh()
        try join(pad, via: phone)
        try join(laptop, via: pad)
        phone.refresh()
        XCTAssertEqual(phone.devicesAdmitted(by: pad.local.id).map(\.id), [laptop.local.id])
        let fake = RemoteGroupFakeAuthenticator(.success)
        let service = service(phone, fake)

        // 别的设备想加入：验证过了照常回 answer。
        mini.startJoin()
        service.tick()
        let request = try XCTUnwrap(service.pendingRequest)
        guard case .showingCode(let code, _) = mini.joinState else { return XCTFail("没显示核对码") }
        let submitted = await service.submit(code, for: request)
        XCTAssertTrue(submitted)
        XCTAssertEqual(roster.load().answers.count, 1)

        let plan = RemoteGroupRemovalPlan(target: pad.local, cascade: phone.devicesAdmitted(by: pad.local.id))
        let removed = await service.remove(plan.ids)
        XCTAssertTrue(removed)
        XCTAssertFalse(phone.members.contains { $0.device.id == pad.local.id || $0.device.id == laptop.local.id })
        XCTAssertEqual(fake.calls, 1, "刚验过（输码那次），5 分钟内移除不再验")

        let left = await service.leave()
        XCTAssertTrue(left)
        XCTAssertFalse(phone.isInGroup)
        XCTAssertEqual(fake.calls, 1)
    }

    func test_cascaded_removal_is_one_prompt() async throws {
        let phone = makeDevice("iPhone"), pad = makeDevice("iPad"), laptop = makeDevice("MacBook")
        phone.refresh()
        try join(pad, via: phone)
        try join(laptop, via: pad)
        phone.refresh()
        let fake = RemoteGroupFakeAuthenticator(.success)
        let service = service(phone, fake)
        let removed = await service.remove([pad.local.id, laptop.local.id])
        XCTAssertTrue(removed)
        XCTAssertEqual(fake.reasons, ["移除「iPad」等 2 台设备"])
        XCTAssertEqual(roster.load().removes.filter { $0.signer == phone.local.id }.count, 2)
    }
}

/// 设备组的界面只调服务上带验证的入口（§19）：这几个界面文件里不许直接调模型的 `remove` / `leave` / `submitCode`。
final class RemoteGroupOwnerCheckLintTests: XCTestCase {
    static let viewFiles = [
        "uTerm/Features/Settings/Views/RemoteMyDevicesGroup.swift",
        "uTerm/Features/Remote/RemoteDeviceGroupPrompt.swift",
        "uTermMobile/Screens/Remote/RemoteMyDevicesScreen.swift",
        "uTermMobile/Screens/Remote/RemoteGroupJoinHandler.swift",
    ]

    /// `接收者.remove(` / `接收者?.leave()` / `接收者.submitCode(`，接收者不是 `service` 的都算。
    static let pattern = try! NSRegularExpression(
        pattern: #"([A-Za-z_][A-Za-z0-9_]*)\s*[?!]?\s*\.\s*(remove\(|leave\(\s*\)|submitCode\()"#)

    static func offenders(in source: String) -> [Int] {
        source.components(separatedBy: "\n").enumerated().compactMap { index, line in
            let code = line.components(separatedBy: "//").first ?? line
            let range = NSRange(code.startIndex..., in: code)
            let hit = pattern.matches(in: code, range: range).contains { match in
                guard let receiver = Range(match.range(at: 1), in: code) else { return true }
                return code[receiver] != "service"
            }
            return hit ? index + 1 : nil
        }
    }

    func test_pattern_catches_direct_model_calls_only() {
        XCTAssertEqual(Self.offenders(in: "model?.remove(ids)"), [1])
        XCTAssertEqual(Self.offenders(in: "if let model { model.leave() }"), [1])
        XCTAssertEqual(Self.offenders(in: "service.model?.submitCode(code, for: id)"), [1])
        XCTAssertEqual(Self.offenders(in: "group . leave( )"), [1])
        XCTAssertEqual(Self.offenders(in: "await service.remove(ids)\nawait service.leave()\nawait service.submit(c, for: r)"), [])
        XCTAssertEqual(Self.offenders(in: "// model.remove(ids)"), [])
    }

    func test_group_views_go_through_the_verified_service_entry_points() throws {
        var found: [String] = []
        for path in Self.viewFiles {
            let url = DefaultsKeyLintTests.repoRoot.appendingPathComponent(path)
            let source = try String(contentsOf: url, encoding: .utf8)
            found += Self.offenders(in: source).map { "\(path):\($0)" }
        }
        XCTAssertTrue(found.isEmpty, """
            设备组的界面直接调了模型的移除 / 离开 / 输码（\(found.count) 处）：
            \(found.joined(separator: "\n"))
            改成 RemoteDeviceGroupService 的 remove(_:) / leave() / submit(_:for:)：它们先验证本人（RemoteGroupOwnerCheck）。
            """)
    }
}

/// 提示把 Mac 加进设备组（§19）：Mac 上「加入」旁的那句说明、组员设备上「未加入的设备」里配对过的 Mac 多的那句话。
@MainActor
final class RemoteDeviceGroupJoinHintTests: XCTestCase {
    private let synced = RemoteMemorySyncedStorage()
    private lazy var roster = RemoteGroupRoster(storage: synced)
    /// 模型只弱引用这两样：这里拿着。
    private var localHosts: [RemoteGroupFakeLocalHost] = []
    private var hostDirectories: [RemoteGroupFakeHosts] = []

    private func makeDevice(_ name: String, platform: RemoteDevicePlatform, model: String? = nil,
                            roster: RemoteGroupRoster? = nil) -> RemoteDeviceGroup {
        let store = RemoteGroupLocalStore(storage: RemoteMemoryStorage())
        let key = try! store.signingKey()
        let local = RemoteGroupDevice(id: UUID(), name: name, model: model, platform: platform.rawValue,
                                      publicKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
                                      signingKey: key.publicKey.rawRepresentation, updatedAt: Date())
        return RemoteDeviceGroup(local: local, signingKey: key, roster: roster ?? self.roster, store: store)
    }

    private func hosting(_ group: RemoteDeviceGroup, accepts: Bool = true) -> RemoteGroupFakeLocalHost {
        let host = RemoteGroupFakeLocalHost()
        host.hostID = group.local.id
        host.accepts = accepts
        localHosts.append(host)
        group.localHost = host
        return host
    }

    func test_mac_hint_shows_only_for_a_hosting_mac_outside_the_group_with_other_devices_around() throws {
        let mac = makeDevice("Mac mini", platform: .mac)
        let phone = makeDevice("iPhone", platform: .mobile)
        let host = hosting(mac)
        phone.refresh()
        mac.refresh()
        XCTAssertTrue(mac.suggestsJoiningLocalMac, "开着被控、没进组、名册里有别的设备")

        host.accepts = false
        XCTAssertFalse(mac.suggestsJoiningLocalMac, "没开被控或没允许担保：进组也不按名单记主控端")
        host.accepts = true
        mac.localHost = nil
        XCTAssertFalse(mac.suggestsJoiningLocalMac, "没交被控端（iOS、测试宿主）")
        mac.localHost = host

        mac.startJoin()
        XCTAssertFalse(mac.suggestsJoiningLocalMac, "正在加入（显示验证码）时不加")
        mac.cancelJoin()
        XCTAssertTrue(mac.suggestsJoiningLocalMac)

        // 不是 Mac 的设备永远没有这句（交了被控端也一样）。
        let pad = makeDevice("iPad", platform: .mobile)
        _ = hosting(pad)
        pad.refresh()
        XCTAssertFalse(pad.suggestsJoiningLocalMac)

        // 名册里没有别的设备：不提。
        let lonely = makeDevice("MacBook", platform: .mac, roster: RemoteGroupRoster(storage: RemoteMemorySyncedStorage()))
        _ = hosting(lonely)
        lonely.refresh()
        XCTAssertTrue(lonely.otherDevices.isEmpty)
        XCTAssertFalse(lonely.suggestsJoiningLocalMac)

        // 进了组：不提。
        mac.startJoin()
        phone.refresh()
        guard case .showingCode(let code, _) = mac.joinState else { return XCTFail("没显示验证码") }
        XCTAssertTrue(phone.submitCode(code, for: mac.local.id))
        mac.refresh()
        phone.refresh()
        mac.refresh()
        XCTAssertTrue(mac.isInGroup)
        XCTAssertFalse(mac.suggestsJoiningLocalMac)

        // 被移出：另有「已被移出」那句，不再提。
        phone.remove([mac.local.id])
        mac.refresh()
        XCTAssertTrue(mac.isSelfRemoved)
        XCTAssertFalse(mac.suggestsJoiningLocalMac)
    }

    func test_outside_row_mentions_pairing_only_for_a_mac_this_device_paired() {
        let mac = RemoteGroupDevice(id: UUID(), name: "Mac Studio", model: "Mac Studio M4", platform: RemoteDevicePlatform.mac.rawValue,
                                    publicKey: Data([1]), signingKey: Data([2]), updatedAt: Date())
        let pad = RemoteGroupDevice(id: UUID(), name: "iPad", model: nil, platform: RemoteDevicePlatform.mobile.rawValue,
                                    publicKey: Data([3]), signingKey: Data([4]), updatedAt: Date())
        let hint = RemoteDeviceGroupCopy.pairedMacOutsideHint
        XCTAssertTrue(RemoteDeviceGroupCopy.isPairedMacOutside(mac, pairedHosts: [mac.id]))
        XCTAssertEqual(RemoteDeviceGroupCopy.outsideSubtitle(mac, pairedHosts: [mac.id]), "Mac Studio M4 · " + hint)
        XCTAssertFalse(RemoteDeviceGroupCopy.isPairedMacOutside(mac, pairedHosts: []), "没配对过")
        XCTAssertEqual(RemoteDeviceGroupCopy.outsideSubtitle(mac, pairedHosts: [UUID()]), "Mac Studio M4")
        XCTAssertFalse(RemoteDeviceGroupCopy.isPairedMacOutside(pad, pairedHosts: [pad.id]), "不是 Mac")
        XCTAssertNil(RemoteDeviceGroupCopy.outsideSubtitle(pad, pairedHosts: [pad.id]))
    }

    func test_model_publishes_the_macs_this_device_paired() {
        let phone = makeDevice("iPhone", platform: .mobile)
        let mac = makeDevice("Mac Studio", platform: .mac)
        mac.refresh()
        phone.refresh()
        XCTAssertTrue(phone.pairedHostIDs.isEmpty, "没交 hosts")
        let directory = RemoteGroupFakeHosts()
        hostDirectories.append(directory)
        directory.addMac("Mac Studio", id: mac.local.id, publicKey: mac.local.publicKey, online: false)
        phone.hosts = directory
        phone.refresh()
        XCTAssertEqual(phone.pairedHostIDs, [mac.local.id])
        XCTAssertTrue(RemoteDeviceGroupCopy.isPairedMacOutside(try! XCTUnwrap(phone.otherDevices.first { $0.id == mac.local.id }),
                                                               pairedHosts: phone.pairedHostIDs))
        directory.paired = []
        phone.refresh()
        XCTAssertTrue(phone.pairedHostIDs.isEmpty, "不再配对就不提")
    }
}
