import CryptoKit
import Foundation
import Observation

/// 设置里「我的设备」的状态与操作，两端共用（Mac 是设置 › 远程控制里的一组，iOS 是单独一页）。
///
/// App 级的 `RemoteSiblingService` 定时调 `refresh()`（全 App 只有一个实例），每次都做这几件事：
/// - 把本机登记进去；
/// - 作为**新设备**：给名册里的每台已有设备写好承诺，回答发给本机的确认；
/// - 作为**已有设备**：推进本机正在做的那次确认。
///
/// 协议见 `RemoteSiblingMessage`。iCloud 钥匙串同步要几秒到几十秒，所以整个过程不会是瞬时的。
///
/// 确认之后（`RemoteSiblingDevices+Grants.swift`）：已有设备逐台向配对过的 Mac 担保新设备，把结果封好写进名册；
/// 新设备收下它认可的担保者封的结果，把 Mac 记进自己的信任表。
@MainActor
@Observable
final class RemoteSiblingDevices {
    /// 列表里的一台设备（不含本机）。
    struct Row: Identifiable, Equatable {
        enum Status: Equatable {
            /// 还没在本机确认过。
            case unconfirmed
            /// 本机确认过。
            case confirmed(Date)
            /// 确认过，但它后来换了钥匙（重装过 uTerm），要重新确认。
            case keyChanged
        }

        let device: RemoteSiblingDevice
        let status: Status
        /// 本机认可它当担保者（确认时本机也点了「一致」，且钥匙没变）。
        var isTrustedVoucher = false
        /// 本机替它开通的进度（本机确认过它时才有）。
        var delivery: Delivery?
        var id: UUID { device.id }
    }

    /// 本机替一台设备开通 Mac 的进度。
    struct Delivery: Equatable {
        /// Mac 记下了它。
        var opened: [String]
        /// 问过、没成（Mac 不允许、太旧、拒绝）。
        var refused: [String]
        /// 还没问到（Mac 不在线、连不上）。
        var waiting: [String]
    }

    /// 一台报告丢了的设备。
    struct Lost: Identifiable, Equatable {
        let tombstone: RemoteSiblingTombstone
        /// 已经撤掉（或那台 Mac 本来就不信它）。
        var revoked: [String]
        /// 撤不了：不是同一组、Mac 版本太旧。名字 → 原因。
        var refused: [String: String]
        /// 还没问到。
        var waiting: [String]
        var id: UUID { tombstone.deviceID }
    }

    /// 别的设备替本机开通的一台 Mac。
    struct Received: Identifiable, Equatable {
        enum Status: Equatable {
            /// 记进了本机的信任表，可以连。
            case opened
            /// 本机早就配对过这台 Mac。
            case alreadyPaired
            /// 本机记着的这台 Mac 公钥和担保者带来的不一样：不覆盖，要手动处理。
            case conflict
            /// 本机忘记过这台 Mac：不加回来。
            case forgotten
            /// Mac 没有记下本机。
            case refused(String)
        }

        let hostID: UUID
        let hostName: String
        let voucherName: String
        let status: Status
        var id: UUID { hostID }
    }

    /// 本机正在确认另一台设备。
    enum Confirmation: Equatable {
        /// 等对方回答（它的 App 开着就会自动答）。
        case waiting(RemoteSiblingDevice)
        /// 对方已经显示出 6 位数，等你在本机输入。本机不显示这个数：要你从对方那里抄过来，才算真的核对过。
        case entering(RemoteSiblingDevice, attemptsLeft: Int)
        case failed(RemoteSiblingDevice, reason: String)

        var device: RemoteSiblingDevice {
            switch self {
            case .waiting(let device), .entering(let device, _), .failed(let device, _): return device
            }
        }
    }

    /// 另一台设备正在确认本机：本机显示 6 位数，你在那台设备上输入，并在本机点「允许」（先后不论）。
    struct Incoming: Identifiable, Equatable {
        let voucher: RemoteSiblingDevice
        let code: String
        /// 那台设备上已经输对了（收到了它封的「核对通过」）。
        let verified: Bool
        var id: UUID { voucher.id }
    }

    /// 核对码最多输错几次。
    static let codeAttempts = 3

    static let pollInterval: Duration = .seconds(2)
    /// 确认等这么久没有回应就放弃。
    static let confirmationTimeout: TimeInterval = 5 * 60
    /// 回答过的确认显示这么久（对方没清掉记录时）。
    static let incomingLifetime: TimeInterval = 10 * 60

    private(set) var rows: [Row] = []
    private(set) var confirmation: Confirmation?
    private(set) var incoming: [Incoming] = []
    /// 别的设备替本机开通的 Mac。
    var received: [Received] = []
    /// 报告丢了的设备，以及本机替它向各台 Mac 撤销的进度。
    var lost: [Lost] = []
    /// 本机自己被另一台设备报告丢了。
    private(set) var localReportedLost = false
    /// 写不进名册（多半是钥匙串不可用）。
    var storageError: String?

    @ObservationIgnored let local: RemoteSiblingDevice
    @ObservationIgnored let roster: RemoteSiblingRoster
    @ObservationIgnored let store: RemoteSiblingLocalStore
    @ObservationIgnored let now: () -> Date
    @ObservationIgnored private var session: Session?
    @ObservationIgnored private var clearedStaleChallenges = false
    /// 本机的远控长期私钥：封、开开通结果用。没有就不做开通这一步（只做确认）。
    @ObservationIgnored let localKey: Curve25519.KeyAgreement.PrivateKey?
    /// 配对过的 Mac（App 里是 `RemoteMacDirectory`）。页面挂上之前是 nil。
    @ObservationIgnored var hosts: (any RemoteSiblingHostAccess)?
    /// 本机此刻在问哪台 Mac（一次只问一台）。
    @ObservationIgnored var vouchTask: Task<Void, Never>?
    /// 每对（设备, Mac）上次问的时间：连不上的过一会儿再问。
    @ObservationIgnored var lastVouchAttempt: [String: Date] = [:]
    /// 本机这边点了「不一致」的确认（对方的随机数）：不再显示。
    @ObservationIgnored private var dismissedChallenges: Set<Data> = []

    /// 本机作为已有设备、正在做的那次确认。
    private struct Session {
        let device: RemoteSiblingDevice
        let startedAt: Date
        /// 开始时看到的对方承诺。之后对方换了承诺也按这一条核对。
        var commitment: Data?
        /// 本机写进 `challenge` 的随机数。
        var nonce: Data?
        var code: String?
        var attemptsLeft = RemoteSiblingDevices.codeAttempts
        var failure: String?
    }

    init(local: RemoteSiblingDevice, localKey: Curve25519.KeyAgreement.PrivateKey? = nil,
         roster: RemoteSiblingRoster = RemoteSiblingRoster(),
         store: RemoteSiblingLocalStore = RemoteSiblingLocalStore(), now: @escaping () -> Date = Date.init) {
        self.local = local
        self.localKey = localKey
        self.roster = roster
        self.store = store
        self.now = now
    }

    /// 用本机的远控身份建一个。读不到身份（钥匙串不可用）返回 nil。`createsIdentity` 见 `RemoteSiblingDevice.local`。
    static func live(createsIdentity: Bool = true) -> RemoteSiblingDevices? {
        let identity = RemoteIdentityStore(role: .hosts)
        guard let local = try? RemoteSiblingDevice.local(name: LANSyncCoordinator.localDeviceName(),
                                                         model: RemoteDeviceModel.current(), identity: identity,
                                                         createsIdentity: createsIdentity) else { return nil }
        return RemoteSiblingDevices(local: local, localKey: identity.existingIdentity())
    }

    var localDevice: RemoteSiblingDevice { local }

    // MARK: - 每一轮

    func refresh() {
        var snapshot = roster.load()
        applyTombstones(&snapshot)
        // 本机被报告丢了：不再登记、不回答确认、不替谁开通，等你在另一台设备上取消报告。
        let reportedLost = snapshot.tombstone(for: local) != nil
        if reportedLost != localReportedLost { localReportedLost = reportedLost }
        guard !reportedLost else {
            rebuildRows(snapshot)
            return
        }
        do {
            try roster.register(local, existing: snapshot.device(local.id))
            storageError = nil
        } catch {
            storageError = String(localized: "没法写入 iCloud 钥匙串：\(error.localizedDescription)")
        }
        if snapshot.device(local.id).map({ !$0.sameIdentity(as: local) }) ?? true {
            snapshot.devices.removeAll { $0.id == local.id }
            snapshot.devices.append(local)
        }
        // 上次没做完的确认不能接着做（随机数只在内存里），把本机发出去的 challenge 清掉。
        if !clearedStaleChallenges {
            clearedStaleChallenges = true
            for message in snapshot.messages where message.kind == .challenge && message.voucher == local.id {
                roster.delete(account: message.account)
            }
            snapshot.messages.removeAll { $0.kind == .challenge && $0.voucher == local.id }
        }
        answerAsCandidate(snapshot)
        advanceSession(snapshot)
        receiveGrants(snapshot)
        vouchNext(snapshot)
        rebuildRows(snapshot)
    }

    // MARK: - 本机是新设备

    func others(_ snapshot: RemoteSiblingSnapshot) -> [RemoteSiblingDevice] {
        snapshot.devices.filter { $0.id != local.id }
    }

    private func answerAsCandidate(_ snapshot: RemoteSiblingSnapshot) {
        var commits = store.commits()
        var shown: [Incoming] = []
        let vouchers = others(snapshot)
        for voucher in vouchers {
            var state = commits[voucher.id]
            // 对方换了钥匙（或第一次见）：重新承诺。
            if state?.voucherKey != voucher.publicKey {
                state = RemoteSiblingCommitState(voucherKey: voucher.publicKey, nonce: RemoteSiblingCode.newNonce())
            }
            guard var current = state else { continue }
            let challenge = snapshot.message(.challenge, candidate: local.id, voucher: voucher.id)
                .flatMap { $0.pairs(candidate: local, voucher: voucher) ? $0 : nil }
            if let challenge, current.answeredChallenge != challenge.value {
                // 先答再换：答出去的随机数作废，下一次确认用新的承诺。
                let code = RemoteSiblingCode.code(candidate: local, voucher: voucher, candidateNonce: current.nonce,
                                                  voucherNonce: challenge.value)
                // 带上对方的随机数：对方只认答它这一次的 reveal，旧的、别人的都不算。
                write(.message(message(.reveal, voucher: voucher, value: current.nonce + challenge.value)))
                current = RemoteSiblingCommitState(voucherKey: voucher.publicKey, nonce: RemoteSiblingCode.newNonce(),
                                                   answeredChallenge: challenge.value, answeredCode: code)
            }
            if let challenge, now().timeIntervalSince(challenge.createdAt) >= Self.incomingLifetime {
                // 过期了没人管：本机清掉这一次的记录。
                clearIncoming(from: voucher.id)
            } else if let challenge, challenge.value == current.answeredChallenge,
                      challenge.value == current.acceptedChallenge {
                // 已经点了「允许」：不再弹窗，等那台设备上输对。收到这一次的「核对通过」就记下它。
                if isConfirmed(by: voucher, challenge: challenge.value, snapshot: snapshot), trust(voucher) {
                    clearIncoming(from: voucher.id)
                }
            } else if let challenge, challenge.value == current.answeredChallenge, let code = current.answeredCode,
               !dismissedChallenges.contains(challenge.value) {
                shown.append(Incoming(voucher: voucher, code: code,
                                      verified: isConfirmed(by: voucher, challenge: challenge.value, snapshot: snapshot)))
            } else if challenge == nil, current.answeredChallenge != nil || current.acceptedChallenge != nil {
                // 对方做完或放弃了：不再显示。
                current.answeredChallenge = nil
                current.answeredCode = nil
                current.acceptedChallenge = nil
            }
            // 对方做完或放弃了，它没清掉本机的回答（App 中途被关）：本机清。
            if challenge == nil, snapshot.message(.reveal, candidate: local.id, voucher: voucher.id) != nil {
                roster.delete(account: RemoteSiblingMessage.account(.reveal, candidate: local.id, voucher: voucher.id))
            }
            let commitment = RemoteSiblingCode.commitment(candidate: local, voucher: voucher, nonce: current.nonce)
            let published = snapshot.message(.commitment, candidate: local.id, voucher: voucher.id)
            if published?.value != commitment || published?.pairs(candidate: local, voucher: voucher) != true {
                write(.message(message(.commitment, voucher: voucher, value: commitment)))
            }
            if current != commits[voucher.id] {
                try? store.setCommit(current, voucher: voucher.id)
                commits[voucher.id] = current
            }
        }
        // 名册里已经没有的设备：清掉本机的承诺。
        let known = Set(vouchers.map(\.id))
        for (voucher, _) in commits where !known.contains(voucher) {
            try? store.setCommit(nil, voucher: voucher)
            roster.delete(account: RemoteSiblingMessage.account(.commitment, candidate: local.id, voucher: voucher))
            roster.delete(account: RemoteSiblingMessage.account(.reveal, candidate: local.id, voucher: voucher))
        }
        let sorted = shown.sorted { $0.voucher.name < $1.voucher.name }
        if sorted != incoming { incoming = sorted }
    }

    /// 那台设备封的「核对通过」打得开，并且是这一次的。
    private func isConfirmed(by voucher: RemoteSiblingDevice, challenge: Data, snapshot: RemoteSiblingSnapshot) -> Bool {
        guard let localKey,
              let message = snapshot.message(.confirmed, candidate: local.id, voucher: voucher.id),
              message.pairs(candidate: local, voucher: voucher),
              let key = try? RemoteSiblingSeal.key(local: localKey, remote: voucher.publicKey) else { return false }
        return RemoteSiblingSeal.openConfirmation(message.value, candidate: local.id, voucher: voucher.id,
                                                  challenge: challenge, key: key)
    }

    /// 撤掉一次确认在名册里留下的记录（本机是新设备）。
    private func clearIncoming(from voucher: UUID) {
        for kind in [RemoteSiblingMessage.Kind.challenge, .reveal, .confirmed] {
            roster.delete(account: RemoteSiblingMessage.account(kind, candidate: local.id, voucher: voucher))
        }
    }

    private func message(_ kind: RemoteSiblingMessage.Kind, voucher: RemoteSiblingDevice, value: Data) -> RemoteSiblingMessage {
        RemoteSiblingMessage(kind: kind, candidate: local.id, candidateKey: local.publicKey, voucher: voucher.id,
                             voucherKey: voucher.publicKey, value: value, createdAt: now())
    }

    // MARK: - 本机是已有设备

    /// 开始确认一台设备。同一时间只做一次确认，再点别的会放弃前一次。
    func confirm(_ id: UUID) {
        let snapshot = roster.load()
        guard let device = snapshot.device(id), id != local.id else { return }
        if let session { cleanUp(session.device) }
        session = Session(device: device, startedAt: now())
        advanceSession(snapshot)
    }

    /// 输入对方显示的 6 位数。对了：记下这台设备，告诉它「核对通过」（它那边再请你点「允许」）；
    /// 错了：少一次机会，用完就停。返回输对没有。
    @discardableResult
    func submitCode(_ text: String) -> Bool {
        guard var session, let code = session.code, session.failure == nil else { return false }
        let digits = text.filter(\.isNumber)
        guard digits == code else {
            session.attemptsLeft -= 1
            if session.attemptsLeft <= 0 {
                session.failure = String(localized: "输错了 \(Self.codeAttempts) 次，这次确认已停止。数字对不上的话，名单里可能有别的设备冒充它。")
                cleanUp(session.device)
            }
            self.session = session
            publishConfirmation()
            return false
        }
        let device = session.device
        do {
            try store.approve(RemoteSiblingApproval(id: device.id, publicKey: device.publicKey,
                                                    name: device.name, approvedAt: now()))
        } catch {
            self.session?.failure = String(localized: "没能保存确认结果：\(error.localizedDescription)")
            publishConfirmation()
            return false
        }
        // 告诉对方：这里输对了。challenge 留着给对方核对「核对通过」是哪一次的，由对方点完后清掉。
        if let localKey, let nonce = session.nonce,
           let key = try? RemoteSiblingSeal.key(local: localKey, remote: device.publicKey),
           let sealed = try? RemoteSiblingSeal.sealConfirmation(candidate: device.id, voucher: local.id,
                                                                challenge: nonce, key: key) {
            write(.message(RemoteSiblingMessage(kind: .confirmed, candidate: device.id, candidateKey: device.publicKey,
                                                voucher: local.id, voucherKey: local.publicKey, value: sealed,
                                                createdAt: now())))
        }
        self.session = nil
        publishConfirmation()
        rebuildRows(roster.load())
        return true
    }

    /// 数不一致、放弃等待，或看过失败原因：结束这次确认，什么都不记。
    func cancel() {
        guard let session else { return }
        cleanUp(session.device)
        self.session = nil
        publishConfirmation()
    }

    /// 取消对一台设备的确认（本机不再替它开通），连同本机对它当担保者的认可。
    func forgetConfirmation(_ id: UUID) {
        try? store.removeApproval(id)
        try? store.removeVoucher(id)
        rebuildRows(roster.load())
    }

    /// 本机是新设备：你点了「允许」（是你自己在那台设备上发起的）。那台设备上已经输对了就马上记下这台担保者；
    /// 还没输对就先记住这次「允许」、关掉弹窗，后台等它封的「核对通过」到了再记（`answerAsCandidate`）。
    /// 两样都要有才算数，先后不论。记下之后收它替本机开通的结果。
    func acceptIncoming(_ voucherID: UUID) {
        guard let shown = incoming.first(where: { $0.voucher.id == voucherID }) else { return }
        if shown.verified {
            guard trust(shown.voucher) else { return }
            clearIncoming(from: voucherID)
        } else {
            guard var state = store.commits()[voucherID], state.voucherKey == shown.voucher.publicKey,
                  let challenge = state.answeredChallenge else { return }
            state.acceptedChallenge = challenge
            do {
                try store.setCommit(state, voucher: voucherID)
            } catch {
                storageError = String(localized: "没能保存确认结果：\(error.localizedDescription)")
                return
            }
        }
        incoming.removeAll { $0.voucher.id == voucherID }
        refresh()
    }

    /// 记下一台担保者。写不进去时报错、返回 false。
    private func trust(_ voucher: RemoteSiblingDevice) -> Bool {
        do {
            try store.trustVoucher(RemoteSiblingApproval(id: voucher.id, publicKey: voucher.publicKey,
                                                         name: voucher.name, approvedAt: now()))
            return true
        } catch {
            storageError = String(localized: "没能保存确认结果：\(error.localizedDescription)")
            return false
        }
    }

    /// 本机是新设备：不是你发起的（或不想让它开通），不再显示，什么都不记。
    func dismissIncoming(_ voucherID: UUID) {
        if let challenge = roster.load().message(.challenge, candidate: local.id, voucher: voucherID) {
            dismissedChallenges.insert(challenge.value)
        }
        clearIncoming(from: voucherID)
        incoming.removeAll { $0.voucher.id == voucherID }
        refresh()
    }

    /// 从名单里移除一台设备（换掉不用的旧设备）。它下次打开 uTerm 会重新登记，要重新确认。
    func remove(_ id: UUID) {
        guard id != local.id else { return }
        if session?.device.id == id { cancel() }
        let snapshot = roster.load()
        roster.remove(id, snapshot: snapshot)
        try? store.removeApproval(id)
        try? store.removeVoucher(id)
        rebuildRows(roster.load())
    }

    /// 「这台设备丢了」：写下墓碑，本机马上不再信它；之后本机和你别的设备逐台请 Mac 撤销它。
    func markLost(_ id: UUID) {
        guard id != local.id else { return }
        let snapshot = roster.load()
        guard let device = snapshot.device(id) else { return }
        if session?.device.id == id { cancel() }
        write(.tombstone(RemoteSiblingTombstone(deviceID: device.id, deviceName: device.name, publicKey: device.publicKey,
                                                revokedBy: local.id, revokedAt: now())))
        refresh()
    }

    /// 找回来了：撤下墓碑。已经撤掉的 Mac 不会自己恢复，那台设备要重新确认、重新开通（或到 Mac 上配对）。
    func clearLostReport(_ id: UUID) {
        roster.delete(account: RemoteSiblingTombstone(deviceID: id, deviceName: "", publicKey: Data(), revokedBy: id,
                                                      revokedAt: now()).account)
        try? store.forgetRevocations(id)
        lost.removeAll { $0.id == id }
        refresh()
    }

    /// 墓碑生效：撤掉本机对它的确认与认可、它在名册里的往来记录（条目留着，名单里按「已丢失」显示，取消报告就回来）；
    /// 过期的墓碑清掉。
    private func applyTombstones(_ snapshot: inout RemoteSiblingSnapshot) {
        for tombstone in snapshot.tombstones where now().timeIntervalSince(tombstone.revokedAt) > RemoteSiblingTombstone.lifetime {
            roster.delete(account: tombstone.account)
            try? store.forgetRevocations(tombstone.deviceID)
        }
        snapshot.tombstones.removeAll { now().timeIntervalSince($0.revokedAt) > RemoteSiblingTombstone.lifetime }
        let approvals = store.approvals(), vouchers = store.trustedVouchers()
        for tombstone in snapshot.tombstones where tombstone.deviceID != local.id {
            if approvals[tombstone.deviceID]?.publicKey == tombstone.publicKey { try? store.removeApproval(tombstone.deviceID) }
            if vouchers[tombstone.deviceID]?.publicKey == tombstone.publicKey { try? store.removeVoucher(tombstone.deviceID) }
            if let device = snapshot.device(tombstone.deviceID), device.publicKey == tombstone.publicKey {
                roster.removeTraffic(of: device.id, snapshot: snapshot)
                snapshot.devices.removeAll { $0.id == device.id }
                snapshot.messages.removeAll { $0.candidate == device.id || $0.voucher == device.id }
                snapshot.grants.removeAll { $0.candidate == device.id || $0.voucher == device.id }
            }
        }
    }

    private func advanceSession(_ snapshot: RemoteSiblingSnapshot) {
        guard var session, session.failure == nil, session.code == nil else {
            publishConfirmation()
            return
        }
        defer {
            self.session = session
            publishConfirmation()
        }
        let device = session.device
        // 对方在名册里换了钥匙或被移除：这次确认作废。
        guard let current = snapshot.device(device.id), current.publicKey == device.publicKey else {
            session.failure = String(localized: "「\(device.name)」在名单里变了（可能重装过 uTerm），这次确认已停止。")
            cleanUp(device)
            return
        }
        if session.nonce == nil {
            guard let commitment = snapshot.message(.commitment, candidate: device.id, voucher: local.id),
                  commitment.pairs(candidate: device, voucher: local) else {
                timeOutIfNeeded(&session)
                return
            }
            let nonce = RemoteSiblingCode.newNonce()
            session.commitment = commitment.value
            session.nonce = nonce
            write(.message(RemoteSiblingMessage(kind: .challenge, candidate: device.id, candidateKey: device.publicKey,
                                                voucher: local.id, voucherKey: local.publicKey, value: nonce,
                                                createdAt: now())))
            return
        }
        // reveal = 对方的随机数 ‖ 本机这次的随机数。后一半对不上的是上一次留下的，或者别人写的，等着。
        guard let nonce = session.nonce, let commitment = session.commitment,
              let reveal = snapshot.message(.reveal, candidate: device.id, voucher: local.id),
              reveal.pairs(candidate: device, voucher: local),
              reveal.value.count == 2 * RemoteSiblingCode.nonceLength, Data(reveal.value.suffix(RemoteSiblingCode.nonceLength)) == nonce
        else {
            timeOutIfNeeded(&session)
            return
        }
        let candidateNonce = Data(reveal.value.prefix(RemoteSiblingCode.nonceLength))
        guard RemoteSiblingCode.commitment(candidate: device, voucher: local, nonce: candidateNonce) == commitment else {
            session.failure = String(localized: "「\(device.name)」答出的数和它事先的承诺对不上，可能有别的设备冒充它。这次确认已停止。")
            cleanUp(device)
            return
        }
        session.code = RemoteSiblingCode.code(candidate: device, voucher: local, candidateNonce: candidateNonce,
                                              voucherNonce: nonce)
    }

    private func timeOutIfNeeded(_ session: inout Session) {
        guard now().timeIntervalSince(session.startedAt) > Self.confirmationTimeout else { return }
        session.failure = String(localized: "等了 5 分钟，「\(session.device.name)」没有回应。确认它开着 iCloud 钥匙串，并打开了「我的设备」。")
        cleanUp(session.device)
    }

    /// 撤掉这次确认在名册里留下的记录。新设备看到 challenge 没了就不再显示数字。
    private func cleanUp(_ device: RemoteSiblingDevice) {
        for kind in [RemoteSiblingMessage.Kind.challenge, .reveal, .confirmed] {
            roster.delete(account: RemoteSiblingMessage.account(kind, candidate: device.id, voucher: local.id))
        }
    }

    private func publishConfirmation() {
        let value: Confirmation? = session.map { session in
            if let failure = session.failure { return .failed(session.device, reason: failure) }
            if session.code != nil { return .entering(session.device, attemptsLeft: session.attemptsLeft) }
            return .waiting(session.device)
        }
        if value != confirmation { confirmation = value }
    }

    // MARK: - 列表

    private func rebuildRows(_ snapshot: RemoteSiblingSnapshot) {
        let approvals = store.approvals()
        let vouchers = store.trustedVouchers()
        let rows = others(snapshot).map { device -> Row in
            let trusted = vouchers[device.id]?.publicKey == device.publicKey
            guard let approval = approvals[device.id] else {
                return Row(device: device, status: .unconfirmed, isTrustedVoucher: trusted)
            }
            guard approval.publicKey == device.publicKey else {
                return Row(device: device, status: .keyChanged, isTrustedVoucher: trusted)
            }
            return Row(device: device, status: .confirmed(approval.approvedAt), isTrustedVoucher: trusted,
                       delivery: delivery(for: device, snapshot: snapshot))
        }
        .sorted { ($0.device.name, $0.device.id.uuidString) < ($1.device.name, $1.device.id.uuidString) }
        if rows != self.rows { self.rows = rows }
        let lost = snapshot.tombstones.filter { $0.deviceID != local.id }
            .sorted { $0.revokedAt > $1.revokedAt }
            .map { revocationProgress(for: $0) }
        if lost != self.lost { self.lost = lost }
    }

    func write(_ record: RemoteSiblingRecord) {
        do {
            try roster.save(record)
        } catch {
            storageError = String(localized: "没法写入 iCloud 钥匙串：\(error.localizedDescription)")
        }
    }
}

// MARK: - 文案（两端共用）

extension RemoteSiblingDevices.Row {
    var subtitle: String {
        let status: String
        switch self.status {
        case .unconfirmed: status = String(localized: "未确认")
        case .confirmed(let date): status = String(localized: "确认于 \(date.formatted(date: .abbreviated, time: .omitted))")
        case .keyChanged: status = String(localized: "重装过 uTerm，要重新确认")
        }
        var parts = [device.modelDetail, status].compactMap(\.self)
        if let delivery {
            if !delivery.opened.isEmpty { parts.append(String(localized: "已替它开通 \(delivery.opened.count) 台 Mac")) }
            if !delivery.waiting.isEmpty { parts.append(String(localized: "\(delivery.waiting.count) 台等上线")) }
            if !delivery.refused.isEmpty { parts.append(String(localized: "\(delivery.refused.count) 台没开通")) }
        }
        if isTrustedVoucher { parts.append(String(localized: "可以替这台设备开通")) }
        return parts.joined(separator: " · ")
    }

    var needsConfirmation: Bool {
        if case .confirmed = status { return false }
        return true
    }
}

extension RemoteSiblingDevices.Received {
    var subtitle: String {
        switch status {
        case .opened: return String(localized: "由「\(voucherName)」开通，可以在主机列表里连接")
        case .alreadyPaired: return String(localized: "这台设备本来就配对过")
        case .conflict: return String(localized: "这台设备记着的身份和「\(voucherName)」带来的不一样，没有改动。可能重装过，要重新配对")
        case .forgotten: return String(localized: "你在这台设备上忘记过它，没有加回来")
        case .refused(let reason): return reason
        }
    }
}

extension RemoteSiblingDevices.Lost {
    var subtitle: String {
        var parts: [String] = []
        if !revoked.isEmpty { parts.append(String(localized: "已从 \(revoked.count) 台 Mac 撤销")) }
        if !waiting.isEmpty { parts.append(String(localized: "\(waiting.count) 台等上线")) }
        if !refused.isEmpty {
            parts.append(String(localized: "\(refused.count) 台要到 Mac 上撤销：\(refused.keys.sorted().joined(separator: "、"))"))
        }
        if parts.isEmpty { parts.append(String(localized: "报告于 \(tombstone.revokedAt.formatted(date: .abbreviated, time: .omitted))")) }
        return parts.joined(separator: " · ")
    }
}

enum RemoteSiblingCopy {
    static let footer = String(localized: "同一 Apple ID 下打开过 uTerm 的设备。点「确认…」，在本机输入对方弹出的 6 位数，就能替它开通你配对过的 Mac。")

    static let receivedHeader = String(localized: "替这台设备开通的 Mac")
    static let receivedFooter = String(localized: "开通后照常在 Mac 列表里连接。那台 Mac 的主人可以随时撤销。")

    static let lostHeader = String(localized: "报告丢失的设备")
    static let lostFooter = String(localized: "你的设备会逐台请 Mac 撤销它。它自己手动配对过的 Mac，要到那台 Mac 上撤销。")
    static let localLost = String(localized: "这台设备被你的另一台设备报告丢失。找回来的话，在那台设备上取消报告。")

    static func lostConfirmTitle(_ name: String) -> String {
        String(localized: "把「\(name)」报告为丢失？")
    }

    static let lostConfirmMessage = String(localized: "你所有的设备都会马上不再信任它，并逐台请配对过的 Mac 撤销它。")

    static func waitingTitle(_ device: RemoteSiblingDevice) -> String {
        String(localized: "正在确认「\(device.name)」")
    }

    static func waitingDetail(_ device: RemoteSiblingDevice) -> String {
        String(localized: "「\(device.name)」会弹出一个 6 位数。它的 uTerm 要开着；iCloud 同步可能要几十秒。")
    }

    static func enteringTitle(_ device: RemoteSiblingDevice) -> String {
        String(localized: "输入「\(device.name)」上显示的 6 位数")
    }

    static func enteringDetail(attemptsLeft: Int) -> String {
        attemptsLeft < RemoteSiblingDevices.codeAttempts
            ? String(localized: "不对，还能再试 \(attemptsLeft) 次。")
            : String(localized: "数字对上才会记下它。")
    }

    static func incomingTitle(_ voucher: RemoteSiblingDevice) -> String {
        String(localized: "「\(voucher.name)」想替这台设备开通远程控制")
    }

    static func incomingDetail(_ voucher: RemoteSiblingDevice) -> String {
        String(localized: "在「\(voucher.name)」上输入这个数，然后点「允许」。不是你发起的，点「拒绝」。")
    }
}
