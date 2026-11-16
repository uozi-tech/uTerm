import Foundation
import Observation

/// 设置里「我的设备」的状态与操作，两端共用（Mac 是设置 › 远程控制里的一组，iOS 是单独一页）。
///
/// 页面开着时每隔几秒读一次名册（`run()`），每次都做三件事（`refresh()`）：
/// - 把本机登记进去；
/// - 作为**新设备**：给名册里的每台已有设备写好承诺，回答发给本机的确认；
/// - 作为**已有设备**：推进本机正在做的那次确认。
///
/// 协议见 `RemoteSiblingMessage`；只有页面开着才轮询，确认时两台设备都要打开这一页。iCloud 钥匙串同步要几秒到
/// 几十秒，所以整个过程不会是瞬时的。P0 只做确认，确认过的设备还不能替谁开通 Mac。
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
        var id: UUID { device.id }
    }

    /// 本机正在确认另一台设备。
    enum Confirmation: Equatable {
        /// 等对方打开「我的设备」、回答。
        case waiting(RemoteSiblingDevice)
        /// 两边都有数了，等你核对。
        case comparing(RemoteSiblingDevice, code: String)
        case failed(RemoteSiblingDevice, reason: String)

        var device: RemoteSiblingDevice {
            switch self {
            case .waiting(let device), .comparing(let device, _), .failed(let device, _): return device
            }
        }
    }

    /// 另一台设备正在确认本机，本机要显示的数。
    struct Incoming: Identifiable, Equatable {
        let voucher: RemoteSiblingDevice
        let code: String
        var id: UUID { voucher.id }
    }

    static let pollInterval: Duration = .seconds(2)
    /// 确认等这么久没有回应就放弃。
    static let confirmationTimeout: TimeInterval = 5 * 60
    /// 回答过的确认显示这么久（对方没清掉记录时）。
    static let incomingLifetime: TimeInterval = 10 * 60

    private(set) var rows: [Row] = []
    private(set) var confirmation: Confirmation?
    private(set) var incoming: [Incoming] = []
    /// 写不进名册（多半是钥匙串不可用）。
    private(set) var storageError: String?

    @ObservationIgnored private let local: RemoteSiblingDevice
    @ObservationIgnored private let roster: RemoteSiblingRoster
    @ObservationIgnored private let store: RemoteSiblingLocalStore
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var session: Session?
    @ObservationIgnored private var clearedStaleChallenges = false

    /// 本机作为已有设备、正在做的那次确认。
    private struct Session {
        let device: RemoteSiblingDevice
        let startedAt: Date
        /// 开始时看到的对方承诺。之后对方换了承诺也按这一条核对。
        var commitment: Data?
        /// 本机写进 `challenge` 的随机数。
        var nonce: Data?
        var code: String?
        var failure: String?
    }

    init(local: RemoteSiblingDevice, roster: RemoteSiblingRoster = RemoteSiblingRoster(),
         store: RemoteSiblingLocalStore = RemoteSiblingLocalStore(), now: @escaping () -> Date = Date.init) {
        self.local = local
        self.roster = roster
        self.store = store
        self.now = now
    }

    /// 用本机的远控身份建一个。读不到身份（钥匙串不可用）返回 nil。
    static func live() -> RemoteSiblingDevices? {
        guard let local = try? RemoteSiblingDevice.local(name: LANSyncCoordinator.localDeviceName(),
                                                         model: RemoteDeviceModel.current()) else { return nil }
        return RemoteSiblingDevices(local: local)
    }

    var localDevice: RemoteSiblingDevice { local }

    /// 页面开着时一直轮询，页面关掉（任务取消）就停。
    func run() async {
        while !Task.isCancelled {
            refresh()
            try? await Task.sleep(for: Self.pollInterval)
        }
    }

    // MARK: - 每一轮

    func refresh() {
        var snapshot = roster.load()
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
        rebuildRows(snapshot)
    }

    // MARK: - 本机是新设备

    private func others(_ snapshot: RemoteSiblingSnapshot) -> [RemoteSiblingDevice] {
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
            if let challenge, challenge.value == current.answeredChallenge, let code = current.answeredCode,
               now().timeIntervalSince(challenge.createdAt) < Self.incomingLifetime {
                shown.append(Incoming(voucher: voucher, code: code))
            } else if challenge == nil, current.answeredChallenge != nil {
                // 对方做完或放弃了：不再显示。
                current.answeredChallenge = nil
                current.answeredCode = nil
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

    /// 两边的数一致：记下这台设备。
    func accept() {
        guard let session, session.code != nil else { return }
        do {
            try store.approve(RemoteSiblingApproval(id: session.device.id, publicKey: session.device.publicKey,
                                                    name: session.device.name, approvedAt: now()))
        } catch {
            self.session?.failure = String(localized: "没能保存确认结果：\(error.localizedDescription)")
            publishConfirmation()
            return
        }
        cleanUp(session.device)
        self.session = nil
        publishConfirmation()
        rebuildRows(roster.load())
    }

    /// 数不一致、放弃等待，或看过失败原因：结束这次确认，什么都不记。
    func cancel() {
        guard let session else { return }
        cleanUp(session.device)
        self.session = nil
        publishConfirmation()
    }

    /// 取消对一台设备的确认。
    func forgetConfirmation(_ id: UUID) {
        try? store.removeApproval(id)
        rebuildRows(roster.load())
    }

    /// 从名单里移除一台设备（换掉不用的旧设备）。它下次打开 uTerm 会重新登记，要重新确认。
    func remove(_ id: UUID) {
        guard id != local.id else { return }
        if session?.device.id == id { cancel() }
        let snapshot = roster.load()
        roster.remove(id, snapshot: snapshot)
        try? store.removeApproval(id)
        rebuildRows(roster.load())
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
        roster.delete(account: RemoteSiblingMessage.account(.challenge, candidate: device.id, voucher: local.id))
        roster.delete(account: RemoteSiblingMessage.account(.reveal, candidate: device.id, voucher: local.id))
    }

    private func publishConfirmation() {
        let value: Confirmation? = session.map { session in
            if let failure = session.failure { return .failed(session.device, reason: failure) }
            if let code = session.code { return .comparing(session.device, code: code) }
            return .waiting(session.device)
        }
        if value != confirmation { confirmation = value }
    }

    // MARK: - 列表

    private func rebuildRows(_ snapshot: RemoteSiblingSnapshot) {
        let approvals = store.approvals()
        let rows = others(snapshot).map { device -> Row in
            guard let approval = approvals[device.id] else { return Row(device: device, status: .unconfirmed) }
            return Row(device: device, status: approval.publicKey == device.publicKey ? .confirmed(approval.approvedAt) : .keyChanged)
        }
        .sorted { ($0.device.name, $0.device.id.uuidString) < ($1.device.name, $1.device.id.uuidString) }
        if rows != self.rows { self.rows = rows }
    }

    private func write(_ record: RemoteSiblingRecord) {
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
        return [device.modelDetail, status].compactMap(\.self).joined(separator: " · ")
    }

    var needsConfirmation: Bool {
        if case .confirmed = status { return false }
        return true
    }
}

enum RemoteSiblingCopy {
    static let footer = String(localized: "同一 Apple ID 下打开过 uTerm 的 iPhone、iPad 和 Mac 会出现在这里（要打开 iCloud 钥匙串）。在这里确认过的设备，以后可以由这台设备替它开通配对过的 Mac，不用再到每台 Mac 上配对一次。只出现在名单里的设备连不上任何 Mac。")

    static func waitingTitle(_ device: RemoteSiblingDevice) -> String {
        String(localized: "正在确认「\(device.name)」")
    }

    static func waitingDetail(_ device: RemoteSiblingDevice) -> String {
        String(localized: "在「\(device.name)」上打开设置 › 远程控制 › 我的设备，两台设备会显示同一个 6 位数。iCloud 同步可能要几十秒。")
    }

    static func comparingTitle(_ device: RemoteSiblingDevice) -> String {
        String(localized: "「\(device.name)」上显示的也是这个数吗？")
    }

    static let comparingDetail = String(localized: "一致才点「一致」。不一致说明名单里可能有别的设备冒充它，点「不一致」。")

    static func incomingTitle(_ voucher: RemoteSiblingDevice) -> String {
        String(localized: "「\(voucher.name)」正在确认这台设备")
    }

    static func incomingDetail(_ voucher: RemoteSiblingDevice) -> String {
        String(localized: "在「\(voucher.name)」上核对这个数，一致就在那边点「一致」。")
    }
}
