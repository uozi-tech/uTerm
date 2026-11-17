import CryptoKit
import Foundation

// 已配对设备担保：一台配对过这台 Mac 的设备，替同在一个设备组里的设备（主控端的「我的设备」），经它和
// Mac 已认证的连接请 Mac 记下同一个人的另一台设备。之后那台设备照常连接，Mac 认识它的设备 ID 与公钥。
//
// 担保不让已配对设备多出权力：它本来就能经远程桌面打开 Mac 的设置出一张邀请。新设备的权限只继承、不放大：
// 担保者此刻勾着公网接入，新设备才勾上。Mac 记下是谁添加的（`RemotePeerVouch`），可以整组撤掉；
// Mac 上关掉「允许担保」后一律拒绝。方案见 docs/remote-shared-pairing-research.md。
//
// 这个文件主控端、被控端、远控进程都编，只放纯数据与规则。

/// 主控端 → Mac：请 Mac 记下这台设备（`RemoteMessage.Kind.vouchDevice`，通道 0）。
nonisolated struct RemoteVouchRequest: Codable, Equatable, Sendable {
    /// 回复里原样带回。
    var requestID: UUID
    var deviceID: UUID
    var name: String
    var model: String?
    /// `RemoteDevicePlatform` 的原始值。
    var platform: String?
    /// 新设备的远控长期公钥（X25519 原始 32 字节）。
    var publicKey: Data
}

/// Mac → 主控端：担保的结果（`RemoteMessage.Kind.vouchResult`）。
nonisolated struct RemoteVouchResult: Codable, Equatable, Sendable {
    /// 结果用字符串存：以后多一种结果，老版本照样解得开整条消息。
    nonisolated enum Outcome: String, Sendable {
        /// 记下了。
        case added
        /// 早就认识它（设备 ID 与公钥都对得上），什么都没改。
        case alreadyTrusted = "already-trusted"
        /// Mac 关掉了「允许担保」。
        case notAllowed = "not-allowed"
        /// 不肯记（它在这台 Mac 上被撤销过、换过钥匙、请求不合法）。
        case rejected
    }

    var requestID: UUID
    var outcome: String
    /// 给人看的原因（`notAllowed` / `rejected` 时）。
    var reason: String?
    /// 新设备能不能经公网接入（继承自担保者）。
    var internetAccess: Bool?
    /// 交给新设备的中继配置（能经公网接入时才有；中继 1.3.0 起是只能连这台 Mac 的成员证书）。
    var relay: RemoteRelayConfig?

    var kind: Outcome? { Outcome(rawValue: outcome) }

    init(requestID: UUID, outcome: Outcome, reason: String? = nil, internetAccess: Bool? = nil,
         relay: RemoteRelayConfig? = nil) {
        self.requestID = requestID
        self.outcome = outcome.rawValue
        self.reason = reason
        self.internetAccess = internetAccess
        self.relay = relay
    }
}

/// 主控端 → Mac：撤销同一组里丢了的那台设备（`RemoteMessage.Kind.revokeSibling`）。
nonisolated struct RemoteSiblingRevokeRequest: Codable, Equatable, Sendable {
    var requestID: UUID
    var deviceID: UUID
    /// 丢了的那台的公钥：Mac 记着的不是这把（它后来重装、重新配对过）就不撤。
    var publicKey: Data
}

/// Mac → 主控端：撤销的结果。
nonisolated struct RemoteSiblingRevokeResult: Codable, Equatable, Sendable {
    nonisolated enum Outcome: String, Sendable {
        /// 撤掉了（之后它再来要到 Mac 上重新配对）。
        case revoked
        /// Mac 本来就不信任它（或记着的是另一把钥匙）：什么都没改。
        case notTrusted = "not-trusted"
        /// 它和请求的设备在这台 Mac 上不是同一组（各自手动配对的）：要到 Mac 上撤销。
        case notInFamily = "not-in-family"
        /// 同一组，但它比请求的设备更早加到这台 Mac、又不是请求者的上游（`RemoteVouchPolicy.decideRevoke` 的资历规则）：
        /// 什么都没改，要由更早的组员来撤，或到 Mac 上撤。老版本的主控端不认识它，落到「认不出的结果」那一支（过一阵再问）。
        case notSenior = "not-senior"
    }

    var requestID: UUID
    var outcome: String
    var reason: String?
    /// `revoked` 时：请求者自己也在这次撤掉的设备里（它撤的是自己的上游，留下的是那一串里更早加到这台 Mac 的设备）。
    /// 回执先发出去，下一拍才断开它。老版本的 Mac 不带（nil）：那时请求者总是留下。
    var requesterRevoked: Bool?

    var kind: Outcome? { Outcome(rawValue: outcome) }

    init(requestID: UUID, outcome: Outcome, reason: String? = nil, requesterRevoked: Bool? = nil) {
        self.requestID = requestID
        self.outcome = outcome.rawValue
        self.reason = reason
        self.requesterRevoked = requesterRevoked
    }
}

/// Mac 记下的、一台设备是谁添加的。不加在 `RemotePeer` 上：升级期间旧的远控进程还在重写信任表，
/// 它不认识的字段会被丢掉。单独存一个账号（`RemoteIdentityStore.vouchAccount`），旧进程不碰它。
nonisolated struct RemotePeerVouch: Codable, Equatable, Sendable {
    var deviceID: UUID
    var deviceName: String
    /// 担保它的设备。
    var vouchedBy: UUID
    var voucherName: String
    /// 同一个人的设备算一组：组号是最早那台（手动配对的）设备的 ID。撤销按组算。
    var family: UUID
    var vouchedAt: Date

    /// 这台 Mac 自己当组员、按设备组记下的（担保者就是这台 Mac，docs/remote-device-group-design.md §7.3「组里的 Mac 互认」）。
    /// 这样记下的设备组号也是这台 Mac 的 ID：它们算一组，可以一起撤掉，也可以互相请 Mac 撤销。
    func isFromDeviceGroup(hostID: UUID) -> Bool { vouchedBy == hostID }
}

/// Mac 对一次担保的判断（纯函数，规则逐条可测）。
nonisolated enum RemoteVouchDecision: Equatable, Sendable {
    case add
    case alreadyTrusted
    case notAllowed(String)
    case rejected(String)
}

nonisolated enum RemoteVouchPolicy {
    static func decide(_ request: RemoteVouchRequest, voucherID: UUID, hostID: UUID, enabled: Bool,
                       isBlocked: Bool, existing: RemotePeer?) -> RemoteVouchDecision {
        guard request.deviceID != voucherID, request.deviceID != hostID else {
            return .rejected(String(localized: "不能担保自己"))
        }
        guard request.publicKey.count == 32,
              (try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: request.publicKey)) != nil,
              !request.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .rejected(String(localized: "请求里的设备身份无效"))
        }
        if let existing {
            // 公钥对得上就是已经认识的；对不上要到 Mac 上重新配对，不能借担保替换钥匙。
            return existing.publicKey == request.publicKey
                ? .alreadyTrusted
                : .rejected(String(localized: "这台设备换过钥匙（可能重装过 uTerm），要到 Mac 上重新配对"))
        }
        // Mac 上撤销过的设备不能借担保回来：那是 Mac 主人的决定。
        guard !isBlocked else {
            return .rejected(String(localized: "这台设备在这台 Mac 上被撤销过，要到 Mac 上重新配对"))
        }
        guard enabled else {
            return .notAllowed(String(localized: "这台 Mac 没有允许已配对的设备为它主人的其它设备开通"))
        }
        return .add
    }

    /// 同一组的设备可以请 Mac 撤销组里的另一台（丢了）。只会减少信任，所以不看「允许担保」开关；
    /// 但只认这台 Mac 上记着的组：各自手动配对的设备，Mac 没有凭据说它们属于同一个人。
    ///
    /// 资历规则（docs/remote-device-group-design.md §18）：同一组里，请求者只能撤 ① 它自己、② 它的上游（担保链上的祖先，
    /// 见 `ancestors`），或 ③ 比它晚加到这台 Mac 的设备（`isAdded(_:before:addedAt:)`）。撤比自己早、又不是自己上游的
    /// 回 `notSenior`。被偷的设备在被移除前替攻击者担保的设备都比被偷之前就在的组员晚，撤不了它们。
    static func decideRevoke(_ request: RemoteSiblingRevokeRequest, requesterID: UUID, existing: RemotePeer?,
                             vouches: [UUID: RemotePeerVouch], trusted: [RemotePeer]) -> RemoteSiblingRevokeResult.Outcome {
        guard let existing, existing.publicKey == request.publicKey else { return .notTrusted }
        guard family(of: request.deviceID, vouches: vouches) == family(of: requesterID, vouches: vouches) else {
            return .notInFamily
        }
        let target = request.deviceID
        if target == requesterID { return .revoked }
        if ancestors(of: requesterID, trusted: Set(trusted.map(\.id)), vouches: vouches).contains(target) { return .revoked }
        return isAdded(requesterID, before: target, addedAt: addedAt(trusted)) ? .revoked : .notSenior
    }

    // MARK: - 资历

    /// 每台设备加到这台 Mac 的时间：信任表里的 `pairedAt`。它由 Mac 自己的钟在记下这把钥匙时写下（手动配对、凭邀请、
    /// 被担保、按设备组记下都一样），之后改名、更新机型、发中继证书、改挂来路都不动它；被撤之后重新加回来、在 Mac 上
    /// 重新配对的算新加的。从不用请求里带的时间。
    static func addedAt(_ trusted: [RemotePeer]) -> [UUID: Date] {
        Dictionary(trusted.map { ($0.id, $0.pairedAt) }, uniquingKeysWith: { first, _ in first })
    }

    /// `a` 比 `b` 早加到这台 Mac。没有时间的当最早（`distantPast`；信任表里的设备都有，只有不在信任表里的才缺）；
    /// 时间相同按设备 ID 的字符串排，小的算早。所以任意两台都分得出先后。
    static func isAdded(_ a: UUID, before b: UUID, addedAt: [UUID: Date]) -> Bool {
        (addedAt[a] ?? .distantPast, a.uuidString) < (addedAt[b] ?? .distantPast, b.uuidString)
    }

    /// 担保链上的祖先，近的在前：它的担保者、担保者的担保者……只走此刻还被信任的设备，碰到这台 Mac 自己、
    /// 手动配对的（没有担保记录）、挂在自己身上的（`reanchor` 之后）、环，就停。
    static func ancestors(of id: UUID, trusted: Set<UUID>, vouches: [UUID: RemotePeerVouch]) -> [UUID] {
        var chain: [UUID] = []
        var seen: Set<UUID> = [id]
        var current = id
        while let voucher = vouches[current]?.vouchedBy, trusted.contains(voucher), !seen.contains(voucher) {
            chain.append(voucher)
            seen.insert(voucher)
            current = voucher
        }
        return chain
    }

    /// 撤 `root` 时留下谁（`cascade` 的 `keeping`）：请求者在 `root` 那一串里（`root` 是它的上游）时，留下的是那一串里
    /// （不含 `root`）最早加到这台 Mac 的那台，不一定是请求者；请求者不在那一串里（`root` 是它担保的、或者别的分支）、
    /// 撤的就是自己时，没有要留的（nil，整串撤掉）。留下的那台连同它担保的不撤。
    ///
    /// 为什么不留请求者：Mac 分不清 `root` 担保过的设备里哪台是主人的、哪台是偷了 `root` 的人加的；后者都是 `root`
    /// 被偷之后才担保的，比主人原有的组员晚，留最早的那台，攻击者抢先撤也只能把自己一起撤掉。
    static func survivor(revoking root: UUID, requester: UUID, trusted: [RemotePeer],
                         vouches: [UUID: RemotePeerVouch]) -> UUID? {
        guard requester != root else { return nil }
        let line = cascade(from: root, keeping: nil, trusted: trusted.map(\.id), vouches: vouches)
        guard line.contains(requester) else { return nil }
        let times = addedAt(trusted)
        return line.filter { $0 != root }.min { isAdded($0, before: $1, addedAt: times) }
    }

    /// 一台设备属于哪一组：它是被担保的就取记录里的组号，否则（手动配对的）就是它自己。
    static func family(of id: UUID, vouches: [UUID: RemotePeerVouch]) -> UUID {
        vouches[id]?.family ?? id
    }

    /// 同组撤销（消息 52）、设备组撤掉被移除的组员时要撤的：`root` 自己，加上一层层由它担保的设备（只看此刻还被信任的；
    /// 担保链按 `vouchedBy` 走），但不含 `keeping`（留下的那台，见 `survivor`），也不顺着 `keeping` 往下走。
    ///
    /// 为什么连带：被偷的设备在被移除之前可以替攻击者的设备担保（组里的、谁都不知道的新钥匙都行）；只撤它一台的话，
    /// 那些设备还被信任，撤销又不拉黑，它们马上能把它担保回来。为什么要留一台：`root` 往往是唯一一台在 Mac 上手动
    /// 配对的设备，组里别的设备都是它担保的；全撤掉就没人能再替正常的组员开通，只能到 Mac 上重新配对。留下的那台
    /// 会替正常的组员重新开通（被移除者签的开通结果不再算数）。
    /// 手动配对的设备没有担保记录，永远不在连带里（`root` 自己除外：它是请求点名要撤的）。
    static func cascade(from root: UUID, keeping: UUID?, trusted: [UUID], vouches: [UUID: RemotePeerVouch]) -> [UUID] {
        var removed: [UUID] = [root]
        var reached: Set<UUID> = [root]
        var frontier = [root]
        while let next = frontier.popLast() {
            for id in trusted where id != keeping && !reached.contains(id) && vouches[id]?.vouchedBy == next {
                reached.insert(id)
                removed.append(id)
                frontier.append(id)
            }
        }
        return removed
    }

    /// 留下的那台（`survivor`）原来的担保者在这次要撤的设备里：它的来路改挂到哪。`root` 的担保者还在（没被撤、此刻还被信任，
    /// 或者就是这台 Mac 自己）就挂到它下面；否则挂在它自己身上（成了这一组的锚点）。组号不改，
    /// `familyMembers` / `decideRevoke` 照旧把它和同组的设备算在一起；担保者的名字（`voucherName`）是给界面的来历。
    /// 只改担保记录，不碰信任表：`pairedAt`（资历）、`vouchedAt` 都不变，改挂不会让它变早或变晚。
    static func reanchor(_ record: RemotePeerVouch, root: UUID, removed: [UUID], hostID: UUID, trusted: [RemotePeer],
                         vouches: [UUID: RemotePeerVouch]) -> RemotePeerVouch {
        var record = record
        guard removed.contains(record.vouchedBy) else { return record }
        if let voucher = vouches[root]?.vouchedBy, !removed.contains(voucher) {
            if voucher == hostID {
                record.vouchedBy = hostID
                return record
            }
            if let peer = trusted.first(where: { $0.id == voucher }) {
                record.vouchedBy = voucher
                record.voucherName = peer.displayName
                return record
            }
        }
        record.vouchedBy = record.deviceID
        return record
    }

    /// 和这台设备同组、此刻还被信任的设备（含它自己）。
    static func familyMembers(of id: UUID, trusted: [RemotePeer], vouches: [UUID: RemotePeerVouch]) -> [UUID] {
        let root = family(of: id, vouches: vouches)
        return trusted.map(\.id).filter { family(of: $0, vouches: vouches) == root }
    }
}
