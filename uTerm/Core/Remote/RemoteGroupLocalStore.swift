import CryptoKit
import Foundation

// 设备组只存本机的那部分（`RemoteSecretStorage`：生产是本机钥匙串，`ThisDeviceOnly`，不同步）。
// 同步的名册谁都能写，所以「我认谁」只能记在本机：同步的话，钥匙串圈里的冒充者能自己写一份名单。

/// 组员上输过码、在等新设备回 Ta 的一次加入。存下来，App 重启后还能核对。
nonisolated struct RemoteGroupPendingJoin: Codable, Equatable, Sendable {
    /// `join` 里的条目：喂进 `finish` 的 AD 就是它的 ID 与两把钥匙。
    var candidate: RemoteGroupDevice
    var sid: Data
    /// 新设备该回的 Ta（`RemoteGroupJoinCrypto.expectedCandidateConfirmation`）。
    var expectedConfirmation: Data
    /// 开 `done` 里条目的钥匙（`RemoteGroupJoinCrypto.entryKey`）。
    var entryKey: Data
    /// 认它时记的加入时间（输码时就定下、也封进了入组包，两边一致）。
    var admittedAt: RemoteGroupTime
    var submittedAt: Date
}

/// 本机的设备组状态。
nonisolated struct RemoteGroupLocalState: Codable, Equatable, Sendable {
    /// 本机认的组员（不含本机）。
    var members: [RemoteGroupMember] = []
    /// 本机记下的移除：每把钥匙只留最晚的一条，不过期。
    var removals: [RemoteGroupRemoval] = []
    /// 本机自己是怎么进组的：经别的设备加入时是入组包里给的；自己当第一台（替别人输过码）时是自己。
    /// 只有一台时为 nil。
    var selfAdmission: RemoteGroupAdmission?
    /// 本机被组里的设备移出了：停止参与、不再写任何记录，直到你重新加入或确认离开。
    var selfRemoved = false
    /// 组员一侧：输过码、在等 Ta 的加入。
    var pendingJoins: [RemoteGroupPendingJoin] = []
    /// 组员一侧：每台新设备最近输过码的时间（限次数用）。
    var submissions: [UUID: [Date]] = [:]

    func member(signingKey: Data) -> RemoteGroupMember? {
        members.first { $0.device.signingKey == signingKey }
    }

    func latestRemoval(of signingKey: Data) -> RemoteGroupTime? {
        removals.first { $0.signingKey == signingKey }?.removedAt
    }

    /// 记下一条移除，只留每把钥匙最晚的那条。返回有没有变。
    @discardableResult
    mutating func recordRemoval(_ removal: RemoteGroupRemoval) -> Bool {
        if let index = removals.firstIndex(where: { $0.signingKey == removal.signingKey }) {
            guard removal.removedAt > removals[index].removedAt else { return false }
            removals[index] = removal
        } else {
            removals.append(removal)
        }
        return true
    }

    /// 去掉已被移除的组员：最晚的一条移除不早于它的加入时间。返回有没有变。
    @discardableResult
    mutating func dropRemovedMembers() -> Bool {
        let current = self
        let kept = members.filter { member in
            current.latestRemoval(of: member.device.signingKey).map { $0 < member.admission.admittedAt } ?? true
        }
        guard kept.count != members.count else { return false }
        members = kept
        return true
    }

    func submissionsLeft(for candidate: UUID, now: Date, window: TimeInterval, limit: Int) -> Int {
        let recent = submissions[candidate, default: []].filter { now.timeIntervalSince($0) < window }
        return max(0, limit - recent.count)
    }

    /// 丢掉窗口外的输码记录。
    mutating func pruneSubmissions(now: Date, window: TimeInterval) {
        submissions = submissions
            .mapValues { $0.filter { now.timeIntervalSince($0) < window } }
            .filter { !$0.value.isEmpty }
    }

    /// 回到只有自己一台：离开原组、被移出后重新开始。移除记录留着（不过期）。
    func solo() -> RemoteGroupLocalState {
        RemoteGroupLocalState(removals: removals)
    }
}

/// 上面的状态与 Ed25519 签名私钥的存取。
nonisolated final class RemoteGroupLocalStore: @unchecked Sendable {
    /// 和远控身份（`identity`、`trustedPeers` 等）在同一个 service 下，账号名带 `group` 前缀不相撞。
    static let signingKeyAccount = "groupSigningKey"
    static let stateAccount = "groupState"

    private let storage: any RemoteSecretStorage
    private let lock = NSLock()

    init(storage: any RemoteSecretStorage = RemoteLocalState.secrets) {
        self.storage = storage
    }

    /// 已经有的签名私钥；没有返回 nil，**不生成**（后台登记、定时刷新只能用这个，见 `existingIdentity` 的说明）。
    func existingSigningKey() -> Curve25519.Signing.PrivateKey? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? storage.load(Self.signingKeyAccount) else { return nil }
        return try? Curve25519.Signing.PrivateKey(rawRepresentation: data)
    }

    /// 签名私钥；没有就生成并保存。只在前台、你打开「我的设备」或点了操作时调。
    func signingKey() throws -> Curve25519.Signing.PrivateKey {
        lock.lock()
        defer { lock.unlock() }
        if let data = try storage.load(Self.signingKeyAccount),
           let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) {
            return key
        }
        let key = Curve25519.Signing.PrivateKey()
        try storage.save(key.rawRepresentation, account: Self.signingKeyAccount)
        return key
    }

    /// 读不出（钥匙串此刻不可用）就抛错，不当成空的：当成空的再写回去，会把整份组员名单清掉。
    /// 读出来解不开（格式坏了）才当空的。
    func state() throws -> RemoteGroupLocalState {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try storage.load(Self.stateAccount) else { return RemoteGroupLocalState() }
        return (try? RemoteGroupFormat.decoder().decode(RemoteGroupLocalState.self, from: data)) ?? RemoteGroupLocalState()
    }

    func save(_ state: RemoteGroupLocalState) throws {
        lock.lock()
        defer { lock.unlock() }
        try storage.save(try RemoteGroupFormat.encoder().encode(state), account: Self.stateAccount)
    }
}

nonisolated extension RemoteGroupDevice {
    /// 本机的条目与签名私钥。远控身份（X25519）与设备 ID 跟主控方向是同一份（`RemoteSiblingDevice.local` 同理）。
    /// `createsIdentity` 为 false 时，身份、设备 ID、签名私钥缺任何一样就抛错，什么都不生成：
    /// 启动时别的地方可能正在第一次生成身份，后台再生成一把会顶掉它。
    static func local(name: String, model: String?, identity: RemoteIdentityStore, store: RemoteGroupLocalStore,
                      createsIdentity: Bool, now: Date = Date()) throws
        -> (device: RemoteGroupDevice, signingKey: Curve25519.Signing.PrivateKey) {
        let identityKey: Curve25519.KeyAgreement.PrivateKey
        let signingKey: Curve25519.Signing.PrivateKey
        if createsIdentity {
            identityKey = try identity.localIdentity()
            signingKey = try store.signingKey()
        } else {
            guard let existing = identity.existingIdentity(),
                  RemoteLocalState.defaults.string(forKey: DefaultsKey.remoteDeviceID) != nil,
                  let existingSigning = store.existingSigningKey() else { throw RemoteProtocolError.notPaired }
            identityKey = existing
            signingKey = existingSigning
        }
        let device = RemoteGroupDevice(id: RemoteLocalDevice.id(), name: name, model: model,
                                       platform: RemoteDevicePlatform.current.rawValue,
                                       publicKey: identityKey.publicKey.rawRepresentation,
                                       signingKey: signingKey.publicKey.rawRepresentation,
                                       updatedAt: RemoteGroupTime(now).date)
        return (device, signingKey)
    }
}
