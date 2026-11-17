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
/// 5. 登记本机条目（只给别的设备列「你的其它设备」用）、清掉本机写过的过期 `join` / `answer` / `done`；
/// 6. 组里的 Mac（§7.2，`RemoteDeviceGroup+Hosts.swift`）：发本机配对过的 Mac 的 `host`、替别的组员问 Mac 并写 `grant`、
///    收别的组员写给本机的 `grant`；
/// 7. 移除之后（§7.3，`RemoteDeviceGroup+Revoke.swift`）：请本机配对过的 Mac 撤销被移除的设备（先于开通），
///    拿掉只凭被移除的组员开通才记下的 Mac；本机是 Mac 时把组员记成自己的主控端（`RemoteDeviceGroup+LocalHost.swift`）。
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
    /// 本机已经核对通过、收下了名单，但组里还没有设备认本机：在等这台组员读到本机的回执、签下 `admit`。
    /// 看到本机认的组员签的、认本机的 `admit` 就清掉。界面上显示「正在等「X」确认」。
    private(set) var awaitingAcknowledgement: RemoteGroupDevice?
    /// 有一次加入在进行（本机在等别的设备的下一步）：轮询该改快。
    private(set) var isAwaitingOthers = false
    /// 组里的 Mac 里本机还不能用的（正在开通，或要单独配对及原因）；都通了就是空的（`RemoteDeviceGroup+Hosts.swift`）。
    private(set) var pendingHosts: [PendingHost] = []
    /// 开通在进行（本机刚进组的 10 分钟里、本机正在替组员问 Mac）：轮询该改快。
    private(set) var isOpeningHosts = false
    /// 被移除的设备里还有 Mac 没撤完的（「已移除的设备」，都撤完了就是空的；`RemoteDeviceGroup+Revoke.swift`）。
    private(set) var removedDevices: [RemovedDevice] = []
    /// 写不进名册或本机钥匙串（多半是钥匙串不可用）。
    var storageError: String?

    var isInGroup: Bool { members.contains { !$0.isLocal } }

    @ObservationIgnored let local: RemoteGroupDevice
    @ObservationIgnored let signingKey: Curve25519.Signing.PrivateKey
    /// 本机的远控身份私钥（X25519）：给组员封中继包、打开组员封给本机的包。没有（测试里、或取不到）时
    /// 本机不替别人开通，收到的结果照收、只是不带中继。
    @ObservationIgnored let identityKey: Curve25519.KeyAgreement.PrivateKey?
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
    /// 本机配对过的 Mac（App 里是 `RemoteMacDirectory`），由 `RemoteDeviceGroupService` 交进来。nil 时不发 `host`、
    /// 不替别人开通、也不收结果。
    @ObservationIgnored weak var hosts: (any RemoteGroupHostAccess)?
    /// 本机是 Mac 时它自己的被控端，由服务交进来（iOS、测试里为 nil）：把组员记成主控端（§7.3「组里的 Mac 互认」）。
    @ObservationIgnored weak var localHost: (any RemoteGroupLocalHost)?
    /// 正在问的 Mac（每台一次只问一个组员）。模型释放时一起取消。
    @ObservationIgnored let vouches = RemoteGroupVouchTasks()
    /// 连不上的 Mac 与那一刻：60 秒内不再问它。
    @ObservationIgnored var hostFailures: [UUID: Date] = [:]
    /// 每一对（组员的签名公钥, Mac）最近一次问完的时刻：60 秒内不再问同一对。
    @ObservationIgnored var lastAsked: [String: Date] = [:]
    /// 本机在这台 Mac 上撤成功（`revoked`，本机自己没被一起撤）、或撤的时候 Mac 回 `not-trusted`（可能是别的组员刚撤过，
    /// 那台组员按资历规则可能连自己也撤了，§18）的时刻：Mac 连带撤掉了由被撤设备担保的主控端（`RemoteVouchPolicy.cascade`），
    /// 其中可能有正常的组员。这之前签的开通结果对这台 Mac 都不再算定论，本机把每台组员再问一遍
    /// （还被信任的回 `already-trusted`，被连带撤掉的重新记下）。只在内存：App 重开后不再补问。
    @ObservationIgnored var revalidateFrom: [UUID: RemoteGroupTime] = [:]
    /// 每台 Mac 上一次交给 `hosts.adopt` 的结果与它的结果：同一条、本机配对状态也没变时不再交。
    @ObservationIgnored var adoptions: [UUID: AdoptionMemo] = [:]
    /// 别的设备写给本机、已经读到过的记录（记一次耗时用）。nil = 还没读过第一轮。
    @ObservationIgnored var arrivals: Set<Data>?
    /// 这一轮有没有写失败过：没失败才清掉 `storageError`。
    @ObservationIgnored private var failedThisRound = false

    init(local: RemoteGroupDevice, signingKey: Curve25519.Signing.PrivateKey,
         identityKey: Curve25519.KeyAgreement.PrivateKey? = nil,
         roster: RemoteGroupRoster = RemoteGroupRoster(), store: RemoteGroupLocalStore = RemoteGroupLocalStore(),
         now: @escaping () -> Date = Date.init) {
        self.local = local
        self.signingKey = signingKey
        // 和本机条目里的公钥不是一对就当没有：封出去的包对方打不开，收到的也打不开。
        self.identityKey = identityKey.flatMap { $0.publicKey.rawRepresentation == local.publicKey ? $0 : nil }
        self.roster = roster
        self.store = store
        self.now = now
    }

    /// 用本机的远控身份建一个。`createsIdentity` 为 false 时缺身份或设备 ID 就返回 nil、什么都不生成；
    /// 两样都有时缺签名私钥会生成一把（见 `RemoteGroupDevice.local`）。
    ///
    /// 名册是包了快通道叠加层的那份（`RemoteGroupOverlayStorage.live`，§7.4）：读到的 = 钥匙串 ∪ 快通道收到的。
    static func live(createsIdentity: Bool = true) -> RemoteDeviceGroup? {
        make(name: LANSyncCoordinator.localDeviceName(), model: RemoteDeviceModel.current(),
             roster: RemoteGroupRoster(storage: RemoteGroupOverlayStorage.live), createsIdentity: createsIdentity)
    }

    static func make(name: String, model: String?, identity: RemoteIdentityStore = RemoteIdentityStore(role: .hosts),
                     store: RemoteGroupLocalStore = RemoteGroupLocalStore(), roster: RemoteGroupRoster = RemoteGroupRoster(),
                     createsIdentity: Bool, now: @escaping () -> Date = Date.init) -> RemoteDeviceGroup? {
        guard let local = try? RemoteGroupDevice.local(name: name, model: model, identity: identity, store: store,
                                                       createsIdentity: createsIdentity, now: now()) else { return nil }
        return RemoteDeviceGroup(local: local.device, signingKey: local.signingKey, identityKey: local.identityKey,
                                 roster: roster, store: store, now: now)
    }

    // MARK: - 每一轮

    func refresh() {
        failedThisRound = false
        defer { if !failedThisRound, storageError != nil { storageError = nil } }
        let snapshot = roster.load()
        noteArrivals(snapshot)
        guard var state = loadState() else { return }
        let original = state
        // 被移出的设备什么都不写；只有你在它上面点了「加入」，才推进那一次加入。
        guard !state.selfRemoved || candidate != nil else {
            haltHostWork()
            publish(state, snapshot)
            return
        }
        advanceCandidate(snapshot, &state)
        guard !state.selfRemoved else {
            haltHostWork()
            persist(state, from: original)
            publish(state, snapshot)
            return
        }
        state = RemoteGroupMembership.resolve(state, snapshot: snapshot, local: local)
        if state.acknowledgementFrom != nil, hasAcceptedAdmitOfSelf(snapshot, state) {
            state.acknowledgementFrom = nil
        }
        if state.selfRemoved {
            AppLogger.notice("设备组：本机被移出了，停止参与", category: RemoteLog.category)
            sentDone = nil
            haltHostWork()
            persist(state, from: original)
            publish(state, snapshot)
            return
        }
        advancePendingJoins(snapshot, &state)
        // 认下的每条移除（含连带的、离线时发生的、重装设备留下的旧身份）都要请 Mac 撤销：从本机的移除记录推出来。
        trackRevocations(&state, names: knownNames(original, state, snapshot))
        persist(state, from: original)
        publishAdmits(snapshot, state)
        register(snapshot)
        cleanUp(snapshot, state)
        // 刚认下的新设备也在 state 里：这一轮就去问 Mac，不等下一轮。
        syncHosts(snapshot, &state)
        publish(state, snapshot)
    }

    /// 本机条目没登记或变了才写。
    private func register(_ snapshot: RemoteGroupSnapshot) {
        guard !snapshot.devices.contains(where: { $0.sameIdentity(as: local) }) else { return }
        write(.device(local))
    }

    /// 补签：本机认的每台组员都要有一条本机签的 `admit`，内容与本机记的一致；不再认的（被移除了、
    /// 或换组前留下的）删掉。补签让添加者后来被移除时，离线过的设备回来也还认它加过的设备。
    /// 组里的第一台（自己加自己）不补签：名册不收这种 `admit`，组里每台设备进组时就从入组包里认了它。
    private func publishAdmits(_ snapshot: RemoteGroupSnapshot, _ state: RemoteGroupLocalState) {
        let mine = snapshot.admits.filter { $0.signer == local.id && $0.signerKey == local.signingKey }
        let countersigned = state.members.filter { !$0.admission.isSelfAdmission(of: $0.device.signingKey) }
        let wanted = Set(countersigned.map { RemoteGroupAdmit.account(device: $0.device.id, signer: local.id) })
        for admit in mine where !wanted.contains(admit.account) {
            roster.delete(account: admit.account)
        }
        let joinedAt = state.selfAdmission?.admittedAt ?? .distantPast
        for member in countersigned {
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
        let names = knownNames(original, state, nil)
        for member in state.members where ids.contains(member.device.id) {
            writeRemoval(of: member, in: &state)
        }
        state.dropRemovedMembers()
        trackRevocations(&state, names: names)
        persist(state, from: original)
        publish(state, roster.load())
    }

    /// 签一条移除这台组员的记录，本机马上记下这条移除、删掉自己给它签的 `admit`（不动名单，调用方 `dropRemovedMembers`）。
    /// removedAt = max(现在, 它的加入时间, 本机的进组时间)：被偷的组员把加入时间写到将来也移得掉。
    func writeRemoval(of member: RemoteGroupMember, in state: inout RemoteGroupLocalState) {
        let joinedAt = state.selfAdmission?.admittedAt ?? .distantPast
        let removedAt = max(RemoteGroupTime(now()), member.admission.admittedAt, joinedAt)
        do {
            let record = try RemoteGroupRemove.make(target: member.device, admission: member.admission,
                                                    removedAt: removedAt, signer: local, key: signingKey)
            write(.remove(record))
            state.recordRemoval(RemoteGroupRemoval(deviceID: member.device.id, publicKey: member.device.publicKey,
                                                   signingKey: member.device.signingKey, removedAt: removedAt,
                                                   admission: member.admission))
            // 同一个设备 ID 的 admit 落在同一个 account 上（重装过的设备新旧两把钥匙共用）：删掉之后，本轮的补签
            // （`publishAdmits`）会给还在组里的那一份重写。
            roster.delete(account: RemoteGroupAdmit.account(device: member.device.id, signer: local.id))
            AppLogger.notice("设备组：移除「\(member.device.name)」", category: RemoteLog.category)
        } catch {
            fail(error)
        }
    }

    /// 本机此刻叫得出名字的设备（按 Ed25519 钥匙）：移除记录里没有名字，「已移除的设备」要显示。
    func knownNames(_ original: RemoteGroupLocalState, _ state: RemoteGroupLocalState,
                    _ snapshot: RemoteGroupSnapshot?) -> [Data: String] {
        var names: [Data: String] = [:]
        for device in snapshot?.devices ?? [] { names[device.signingKey] = device.name }
        for admit in snapshot?.admits ?? [] { names[admit.device.signingKey] = admit.device.name }
        for member in original.members + state.members { names[member.device.signingKey] = member.device.name }
        return names
    }

    /// 移除连带：由这台设备加进来的组员，连同它们再加进来的，一层层算下去（不经过本机：本机加的设备不连带）。
    /// 移除一台设备时默认一起移除，可以取消勾选。
    ///
    /// 要算到底：只算直接加的，被偷的组员先加一台自己的设备、再由那台去加别的，后加的就不在名单里。
    /// 链条也经过已经移除的设备（带着加入信息记下的），先加一台、再移除它也断不了链。
    /// 「是谁加的」带着添加者的签名（`RemoteGroupAdmission`），补签的设备改不了。
    func devicesAdmitted(by id: UUID) -> [RemoteGroupDevice] {
        guard let state = try? store.state() else { return [] }
        let root = id == local.id ? local.signingKey : state.members.first { $0.device.id == id }?.device.signingKey
        guard let root else { return [] }
        let edges = state.members.map { (admitter: $0.admission.admitterKey, key: $0.device.signingKey) }
            + state.removals.compactMap { removal in removal.admission.map { (admitter: $0.admitterKey, key: removal.signingKey) } }
        var reached: Set<Data> = [root]
        var frontier = [root]
        while let next = frontier.popLast() {
            for edge in edges where edge.admitter == next && edge.key != local.signingKey && reached.insert(edge.key).inserted {
                frontier.append(edge.key)
            }
        }
        return state.members.filter { $0.device.signingKey != root && reached.contains($0.device.signingKey) }.map(\.device)
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
            write(.remove(try RemoteGroupRemove.make(target: local, admission: state.selfAdmission, removedAt: removedAt,
                                                     signer: local, key: signingKey)))
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
        // done：组里已经有设备认了本机（看得到它签的 admit），或者等太久了。
        for done in snapshot.dones where done.candidate == local.id && !(sentDone?.sameContent(as: done) ?? false) {
            if hasAcceptedAdmitOfSelf(snapshot, state)
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
            .map { member in
                // 第一台（自己加自己）没有添加者。
                let admitter = member.admission.isSelfAdmission(of: member.device.signingKey)
                    ? nil : names[member.admission.admitterKey]
                return MemberRow(device: member.device, isLocal: false, admittedByName: admitter)
            }
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
        let waitingFor = state.acknowledgementFrom.flatMap { id in state.members.first { $0.device.id == id }?.device }
        if waitingFor != awaitingAcknowledgement { awaitingAcknowledgement = waitingFor }
        // 「在等」只算最近这 10 分钟里的事：核对结果要留着等 24 小时（对方可能很久才上线），但不能让轮询
        // 跟着快一整天。
        func isRecent(_ date: Date) -> Bool { now().timeIntervalSince(date) <= Self.codeLifetime }
        let joinedRecently = state.selfAdmission.map { isRecent($0.admittedAt.date) } ?? false
        let submittedRecently = state.pendingJoins.contains { isRecent($0.submittedAt) }
        let awaiting = candidate != nil
            || !state.selfRemoved && ((sentDone != nil || waitingFor != nil) && joinedRecently || submittedRecently)
        if awaiting != isAwaitingOthers { isAwaitingOthers = awaiting }
    }

    /// 本机认的某台组员签了认本机这一次加入的 `admit`（加入信息与本机记的相同：旧组、上一次加入时留下的不算）。
    func hasAcceptedAdmitOfSelf(_ snapshot: RemoteGroupSnapshot, _ state: RemoteGroupLocalState) -> Bool {
        guard let admission = state.selfAdmission else { return false }
        let signers = RemoteGroupMembership.Signers(state: state, local: local)
        return snapshot.admits.contains {
            $0.device.signingKey == local.signingKey && $0.signerKey != local.signingKey && $0.admission == admission
                && signers.accepts($0.signer, key: $0.signerKey, at: $0.signedAt)
        }
    }

    /// 组里 Mac 的状态只在变了时才写。
    func updateHostState(pending: [PendingHost], opening: Bool) {
        if pending != pendingHosts { pendingHosts = pending }
        if opening != isOpeningHosts { isOpeningHosts = opening }
    }

    /// 「已移除的设备」只在变了时才写。
    func setRemovedDevices(_ rows: [RemovedDevice]) {
        if rows != removedDevices { removedDevices = rows }
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
        let message = String(localized: "无法写入 iCloud 钥匙串：\(error.localizedDescription)")
        if storageError != message { storageError = message }
    }
}
