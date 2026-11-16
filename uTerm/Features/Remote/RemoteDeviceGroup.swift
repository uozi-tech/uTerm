import CryptoKit
import Foundation
import Observation

/// 设置里「我的设备」：设备组的状态与操作，两端共用。方案见 docs/remote-device-group-design.md（§7.1 是规格）。
///
/// App 级的服务定时调 `refresh()`（全 App 只有一个实例），每一轮：
/// 1. 新设备一侧：看组员有没有回本机当前这个数，核对通过就收下名单、回 `done`（`RemoteDeviceGroup+Join.swift`）；
/// 2. 按 `admit` / `remove` 算组员名单（`RemoteGroupMembership`）。本机被移出了就到此为止，之后什么都不写；
/// 3. 组员一侧：核对新设备回的 Ta，对了才认它；
/// 4. 给认的每台组员补签一条自己的 `admit`，删掉不再认的；
/// 5. 登记本机条目（只给别的设备列「你的其它设备」用）、清掉本机写过的过期 `join` / `answer` / `done`。
///
/// 每一跳都是 iCloud 钥匙串同步，几秒到几十秒。
@MainActor
@Observable
final class RemoteDeviceGroup {
    /// 组员名单里的一行。
    struct MemberRow: Identifiable, Equatable {
        let device: RemoteGroupDevice
        /// 这台设备（本机）。
        let isLocal: Bool
        /// 最初把它加进来的设备的名字。本机自己当第一台、或添加者已不在名单里时为 nil。
        let admittedByName: String?
        var id: Data { device.signingKey }
    }

    /// 本机作为新设备的加入进度。
    enum JoinState: Equatable {
        /// 屏幕上显示这个数，等你在组里任意一台设备上输入。
        case showingCode(String, attemptsLeft: Int)
        /// 核对通过，已经加入。
        case joined
        case failed(String)
    }

    /// 别的设备想加入（本机是组员）：弹输码框用。
    struct JoinRequest: Identifiable, Equatable {
        enum Status: Equatable {
            /// 等你输入它屏幕上的数。
            case waitingForCode(attemptsLeft: Int)
            /// 输了，在等它回话（输码框可以关掉，后台继续）。
            case verifying
            /// 上一次输的不对，它已经换了新数。
            case wrongCode(attemptsLeft: Int)
            /// 10 分钟内输够了次数。
            case limitReached
            /// 核对通过，本机已经认了它。
            case admitted
        }

        let candidate: RemoteGroupDevice
        let status: Status
        var id: UUID { candidate.id }
    }

    /// 新设备上：最多换几个数（每个数只试一次）。
    static let codeAttempts = 3
    /// 一个数、一次加入请求多久过期。
    static let codeLifetime: TimeInterval = 10 * 60
    /// 组员上：同一台新设备 10 分钟内最多输几次。
    static let submissionLimit = 3
    static let submissionWindow: TimeInterval = 10 * 60
    /// 组员输码后等 Ta、新设备等 `admit` 回执，最多这么久。Ta 猜不出来，等久一点只为了对方离线时还能接上
    /// （只在 `codeLifetime` 之内显示「正在核对」）。
    static let pendingLifetime: TimeInterval = 24 * 3600
    static let pollInterval: Duration = .seconds(2)

    /// 组员名单，本机在第一行。只有本机一台时就这一行。
    private(set) var members: [MemberRow] = []
    /// 名册里登记过、不在本机组里的设备。只用来显示：条目谁都能写，名字、ID 都不可信。
    private(set) var otherDevices: [RemoteGroupDevice] = []
    /// 本机被组里的设备移出了。
    private(set) var isSelfRemoved = false
    private(set) var joinState: JoinState?
    private(set) var joinRequests: [JoinRequest] = []
    /// 有一次加入在进行（本机在等别的设备的下一步）：轮询该改快。
    private(set) var isAwaitingOthers = false
    /// 写不进名册或本机钥匙串（多半是钥匙串不可用）。
    var storageError: String?

    var isInGroup: Bool { members.contains { !$0.isLocal } }

    @ObservationIgnored let local: RemoteGroupDevice
    @ObservationIgnored let signingKey: Curve25519.Signing.PrivateKey
    @ObservationIgnored let roster: RemoteGroupRoster
    @ObservationIgnored let store: RemoteGroupLocalStore
    @ObservationIgnored let now: () -> Date
    /// 本机作为新设备、当前这个数。只在内存：App 重开后旧数作废（名册里的 `join` 会被清掉），要重新点「加入」。
    @ObservationIgnored var candidate: CandidateSession?
    /// 本机作为新设备回出去、还没等到对方 `admit` 的 `done`：名册里被删了或被改了就重写。
    @ObservationIgnored var sentDone: RemoteGroupDone?
    /// 你在本机点了「拒绝」的那几轮加入（按 sid）。
    @ObservationIgnored var dismissedJoins: Set<Data> = []
    /// 本机核对通过、认下的新设备：显示「已加入」直到你关掉。
    @ObservationIgnored var admittedJoins: [UUID: RemoteGroupDevice] = [:]
    /// 这一轮有没有写失败过：没失败才清掉 `storageError`。
    @ObservationIgnored private var failedThisRound = false

    init(local: RemoteGroupDevice, signingKey: Curve25519.Signing.PrivateKey,
         roster: RemoteGroupRoster = RemoteGroupRoster(), store: RemoteGroupLocalStore = RemoteGroupLocalStore(),
         now: @escaping () -> Date = Date.init) {
        self.local = local
        self.signingKey = signingKey
        self.roster = roster
        self.store = store
        self.now = now
    }

    /// 用本机的远控身份建一个。`createsIdentity` 为 false 时缺身份或签名私钥就返回 nil，什么都不生成
    /// （见 `RemoteGroupDevice.local`）。
    static func live(createsIdentity: Bool = true) -> RemoteDeviceGroup? {
        make(name: LANSyncCoordinator.localDeviceName(), model: RemoteDeviceModel.current(),
             createsIdentity: createsIdentity)
    }

    static func make(name: String, model: String?, identity: RemoteIdentityStore = RemoteIdentityStore(role: .hosts),
                     store: RemoteGroupLocalStore = RemoteGroupLocalStore(), roster: RemoteGroupRoster = RemoteGroupRoster(),
                     createsIdentity: Bool, now: @escaping () -> Date = Date.init) -> RemoteDeviceGroup? {
        guard let local = try? RemoteGroupDevice.local(name: name, model: model, identity: identity, store: store,
                                                       createsIdentity: createsIdentity, now: now()) else { return nil }
        return RemoteDeviceGroup(local: local.device, signingKey: local.signingKey, roster: roster, store: store, now: now)
    }

    // MARK: - 每一轮

    func refresh() {
        failedThisRound = false
        defer { if !failedThisRound, storageError != nil { storageError = nil } }
        let snapshot = roster.load()
        guard var state = loadState() else { return }
        let original = state
        guard !state.selfRemoved else {
            publish(state, snapshot)
            return
        }
        advanceCandidate(snapshot, &state)
        state = RemoteGroupMembership.resolve(state, snapshot: snapshot, local: local)
        if state.selfRemoved {
            AppLogger.notice("设备组：本机被移出了，停止参与", category: RemoteLog.category)
            candidate = nil
            sentDone = nil
            updateJoinState(nil)
            persist(state, from: original)
            publish(state, snapshot)
            return
        }
        advancePendingJoins(snapshot, &state)
        persist(state, from: original)
        publishAdmits(snapshot, state)
        register(snapshot)
        cleanUp(snapshot, state)
        publish(state, snapshot)
    }

    /// 本机条目没登记或变了才写。
    private func register(_ snapshot: RemoteGroupSnapshot) {
        guard !snapshot.devices.contains(where: { $0.sameIdentity(as: local) }) else { return }
        write(.device(local))
    }

    /// 补签：本机认的每台组员都要有一条本机签的 `admit`，内容与本机记的一致；不再认的（被移除了、
    /// 或换组前留下的）删掉。补签让添加者后来被移除时，离线过的设备回来也还认它加过的设备。
    private func publishAdmits(_ snapshot: RemoteGroupSnapshot, _ state: RemoteGroupLocalState) {
        let mine = snapshot.admits.filter { $0.signer == local.id && $0.signerKey == local.signingKey }
        let wanted = Set(state.members.map { RemoteGroupAdmit.account(device: $0.device.id, signer: local.id) })
        for admit in mine where !wanted.contains(admit.account) {
            roster.delete(account: admit.account)
        }
        let joinedAt = state.selfAdmission?.admittedAt ?? .distantPast
        for member in state.members {
            guard !mine.contains(where: { $0.matches(member) && $0.signedAt >= joinedAt }) else { continue }
            let signedAt = max(RemoteGroupTime(now()), joinedAt)
            do {
                write(.admit(try RemoteGroupAdmit.make(device: member.device, admission: member.admission, signer: local,
                                                       signedAt: signedAt, key: signingKey)))
            } catch {
                fail(error)
            }
        }
    }

    // MARK: - 移除

    /// 从组里移除这些设备（按设备 ID；本机不行，用 `leave()`）。组里所有设备读到后都不再认它们。
    func remove(_ ids: [UUID]) {
        guard var state = loadState(), !state.selfRemoved else { return }
        let original = state
        let joinedAt = state.selfAdmission?.admittedAt ?? .distantPast
        for member in state.members where ids.contains(member.device.id) {
            let removedAt = max(RemoteGroupTime(now()), member.admission.admittedAt, joinedAt)
            do {
                let record = try RemoteGroupRemove.make(target: member.device, removedAt: removedAt, signer: local,
                                                        key: signingKey)
                write(.remove(record))
                state.recordRemoval(record.removal)
                roster.delete(account: RemoteGroupAdmit.account(device: member.device.id, signer: local.id))
                AppLogger.notice("设备组：移除「\(member.device.name)」", category: RemoteLog.category)
            } catch {
                fail(error)
            }
        }
        state.dropRemovedMembers()
        persist(state, from: original)
        publish(state, roster.load())
    }

    /// 移除连带：最初由这台设备加进来的组员（只算它直接加的）。移除一台设备时默认一起移除，可以取消勾选。
    func devicesAdmitted(by id: UUID) -> [RemoteGroupDevice] {
        guard let state = try? store.state() else { return [] }
        let key = id == local.id ? local.signingKey : state.members.first { $0.device.id == id }?.device.signingKey
        guard let key else { return [] }
        return state.members
            .filter { $0.admission.admitterID == id && $0.admission.admitterKey == key && $0.device.signingKey != key }
            .map(\.device)
    }

    /// 离开所在的组（换组、或被移出后确认）：签一条移除自己的 `remove`，删掉本机签过的所有 `admit`，
    /// 回到只有自己一台。被移出时不再签（组里已经不认本机了），只清本机。
    func leave() {
        guard var state = loadState() else { return }
        if !state.selfRemoved, !state.members.isEmpty {
            writeLeave(state)
        }
        deleteOwnAdmits(roster.load())
        state = state.solo()
        persist(state)
        sentDone = nil
        admittedJoins = [:]
        publish(state, roster.load())
    }

    /// 本机签的离开记录。时间不早于本机这次加入，组员才认（`RemoteGroupMembership.Signers`）。
    func writeLeave(_ state: RemoteGroupLocalState) {
        let removedAt = max(RemoteGroupTime(now()), state.selfAdmission?.admittedAt ?? .distantPast)
        do {
            write(.remove(try RemoteGroupRemove.make(target: local, removedAt: removedAt, signer: local, key: signingKey)))
            AppLogger.notice("设备组：本机离开原来的组", category: RemoteLog.category)
        } catch {
            fail(error)
        }
    }

    /// 换组前要删干净：留着的话，新组的设备认了本机，就会顺着这些旧 `admit` 把原来组里的设备也认进去。
    /// （删了也可能被钥匙串圈里的人写回来，所以新组只认本机进组之后签的，见 `RemoteGroupAdmit.signedAt`。）
    func deleteOwnAdmits(_ snapshot: RemoteGroupSnapshot) {
        for admit in snapshot.admits where admit.signer == local.id {
            roster.delete(account: admit.account)
        }
    }

    // MARK: - 清理

    /// 本机写过、已经没用的加入记录。
    private func cleanUp(_ snapshot: RemoteGroupSnapshot, _ state: RemoteGroupLocalState) {
        // join：本机没在加入（取消了、做完了，或 App 重开过、内存里的数没了）。
        if candidate == nil, snapshot.joins.contains(where: { $0.device.id == local.id }) {
            roster.delete(account: RemoteGroupJoin.account(local.id))
        }
        // done：对方已经认了本机（看得到它签的 admit），或者等太久了。
        for done in snapshot.dones where done.candidate == local.id && !(sentDone?.sameContent(as: done) ?? false) {
            if isAcknowledged(done, snapshot: snapshot, state: state)
                || now().timeIntervalSince(done.createdAt) > Self.pendingLifetime {
                roster.delete(account: done.account)
            }
        }
        // answer：本机已经不在等那台新设备的 Ta 了。
        let waiting = Set(state.pendingJoins.map(\.candidate.id))
        for answer in snapshot.answers where answer.member.id == local.id && !waiting.contains(answer.candidate) {
            roster.delete(account: answer.account)
        }
    }

    // MARK: - 输出

    func publish(_ state: RemoteGroupLocalState, _ snapshot: RemoteGroupSnapshot) {
        var names = [local.signingKey: local.name]
        for member in state.members { names[member.device.signingKey] = member.device.name }
        let localAdmitter = state.selfAdmission.flatMap { $0.admitterKey == local.signingKey ? nil : names[$0.admitterKey] }
        let rows = [MemberRow(device: local, isLocal: true, admittedByName: localAdmitter)]
            + state.members
            .sorted { ($0.device.name, $0.device.id.uuidString) < ($1.device.name, $1.device.id.uuidString) }
            .map { MemberRow(device: $0.device, isLocal: false, admittedByName: names[$0.admission.admitterKey]) }
        if rows != members { members = rows }

        let accepted = Set(state.members.map(\.device.signingKey)).union([local.signingKey])
        var seen = Set<UUID>()
        let others = snapshot.devices
            .filter { !accepted.contains($0.signingKey) && $0.id != local.id }
            .sorted { ($0.name, $0.updatedAt) < ($1.name, $1.updatedAt) }
            .filter { seen.insert($0.id).inserted }
        if others != otherDevices { otherDevices = others }

        if state.selfRemoved != isSelfRemoved { isSelfRemoved = state.selfRemoved }
        let requests = buildRequests(state, snapshot)
        if requests != joinRequests { joinRequests = requests }
        let awaiting = !state.selfRemoved && (candidate != nil || sentDone != nil || !state.pendingJoins.isEmpty)
        if awaiting != isAwaitingOthers { isAwaitingOthers = awaiting }
    }

    /// 加入进度只在变了时才写（`@Observable` 每次赋值都会通知界面）。
    func updateJoinState(_ value: JoinState?) {
        if value != joinState { joinState = value }
    }

    // MARK: - 存取

    func loadState() -> RemoteGroupLocalState? {
        do {
            return try store.state()
        } catch {
            fail(error)
            return nil
        }
    }

    @discardableResult
    func persist(_ state: RemoteGroupLocalState, from original: RemoteGroupLocalState? = nil) -> Bool {
        guard state != original else { return true }
        do {
            try store.save(state)
            return true
        } catch {
            fail(error)
            return false
        }
    }

    func write(_ record: RemoteGroupRecord) {
        do {
            try roster.save(record)
        } catch {
            fail(error)
        }
    }

    func fail(_ error: Error) {
        failedThisRound = true
        let message = String(localized: "没法写入 iCloud 钥匙串：\(error.localizedDescription)")
        if storageError != message { storageError = message }
    }
}
