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
    /// 认它时用的加入信息（输码时就由本机签好、也封进了入组包，两边一致）。
    var admission: RemoteGroupAdmission
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
    /// 本机核对通过、收下了名单，但还没看到任何一台组员签的认本机的 `admit`：在等这台组员（设备 ID）读到
    /// `done`。在此之前别的设备都还不认本机。
    var acknowledgementFrom: UUID?
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

    /// 记下一条移除，只留每把钥匙最晚的那条。它当初怎么进的组（`admission`）取最晚那次移除带的；
    /// 一旦知道就留着，不被后来不带这份信息的移除冲掉。返回有没有变。
    @discardableResult
    mutating func recordRemoval(_ removal: RemoteGroupRemoval) -> Bool {
        guard let index = removals.firstIndex(where: { $0.signingKey == removal.signingKey }) else {
            removals.append(removal)
            return true
        }
        var merged = removals[index]
        if removal.removedAt > merged.removedAt {
            merged.removedAt = removal.removedAt
            merged.deviceID = removal.deviceID
            merged.admission = removal.admission ?? merged.admission
        } else if merged.admission == nil {
            merged.admission = removal.admission
        }
        guard merged != removals[index] else { return false }
        removals[index] = merged
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

    /// 已经有的签名私钥；没有返回 nil，不生成。
    func existingSigningKey() -> Curve25519.Signing.PrivateKey? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? storage.load(Self.signingKeyAccount) else { return nil }
        return try? Curve25519.Signing.PrivateKey(rawRepresentation: data)
    }

    /// 签名私钥；没有就生成并保存。远控身份已经在了才调（见 `RemoteGroupDevice.local`）。
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
    /// 本机的条目与签名私钥。远控身份（X25519）与设备 ID 跟主控方向是同一份（握手里报的就是它们）。
    /// `createsIdentity` 为 false（后台）时，身份或设备 ID 缺一样就抛错、什么都不生成：启动时别的地方可能正在
    /// 第一次生成身份，后台再生成一把会顶掉它。两样都有、只缺签名私钥时照样生成签名私钥：它只归设备组用，
    /// 没有别处会同时生成；不生成的话，用着远程控制、但从没打开过「我的设备」的设备永远不会登记，也弹不出加入请求。
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
                  RemoteLocalState.defaults.string(forKey: DefaultsKey.remoteDeviceID) != nil else {
                throw RemoteProtocolError.notPaired
            }
            identityKey = existing
            signingKey = try store.signingKey()
        }
        let device = RemoteGroupDevice(id: RemoteLocalDevice.id(), name: name, model: model,
                                       platform: RemoteDevicePlatform.current.rawValue,
                                       publicKey: identityKey.publicKey.rawRepresentation,
                                       signingKey: signingKey.publicKey.rawRepresentation,
                                       updatedAt: RemoteGroupTime(now).date)
        return (device, signingKey)
    }
}
