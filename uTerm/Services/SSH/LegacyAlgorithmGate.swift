import Foundation
import Synchronization
import USSHKit

/// 自动退到 SHA-1 时代的旧算法之前，App 这一头的决定（USSHKit 的 `legacyFallbackApproval`）。
///
/// 维护者定的规则：**一直只会 SHA-1 的老设备照旧静默连；以前用现代算法连上过、这次却要退到旧算法的，先问用户。**
/// 「以前连上过」看主机密钥信任库（`KnownHost`）里有没有这台 host:port；「一直只会 SHA-1」看本机记着的
/// 同意（`LegacyAlgorithmConsent`）。判定本身是纯函数 `decide`：
///
/// | 本机记着同意过 | 信任库里有记录 | 核对主机密钥 | 结果 |
/// |---|---|---|---|
/// | 是 | — | — | 照常连 |
/// | 否 | 否（第一次连） | — | 照常连（之后照常走新主机的信任确认） |
/// | 否 | — | 否（设置里关了核对） | 照常连，但连上了也不记：中间人本来就能冒充它，问连接方式没有意义 |
/// | 否 | 是 | 是 | 问用户 |
///
/// 旧栈（Citadel + Wellz 的 swift-nio-ssh，SSH 栈换成 USSHKit 之前）**协商不到**这些旧算法：它只带 NIOSSH
/// 自带的 curve25519 / ECDH 密钥交换、ed25519 / ECDSA 主机密钥和 AES-GCM，Citadel 的 `ssh-rsa`、group14-sha1、
/// `hmac-sha1`（`SSHAlgorithms.all`）uTerm 从来没登记过。所以升级前写下的每一条 `KnownHost` 都是用现代算法连上的，
/// 不会因为升级被误问。会误问的只有一种：设备 A 第一次就用旧算法连上一台老设备（静默、只在 A 上记下同意），
/// 它的 `KnownHost` 经 iCloud 同步到设备 B，B 第一次连时会问一次（同意记在本机，不同步）。
///
/// **同意只按连上之后 USSHKit 报的结果写**（`record`，读 `ConnectedClient.targetNeededLegacyTransport` /
/// `bastionNeededLegacyTransport`）：这一跳的传输层这次真的要旧算法（`true`）记下，用的是现代算法（`false`）清掉，
/// 没读懂服务器的握手（`nil`）不动。钩子里（`approve`）什么都不记：中间人只篡改第一次的明文 KEXINIT 就能让钩子被调、
/// 用户被问；同意之后真正的服务器照样协商到现代算法，结果是 `false`，同意随之清掉，不会被植入一条。同样不能按
/// 「钩子有没有被调」去清——加密是 AES-GCM、服务器只报了 `hmac-sha1` 名字的那类服务器每次都会触发钩子，
/// 结果却是 `true`，它要记着。于是服务器升级之后又退回 SHA-1，会再问一次——这正是这个提示要拦的。
/// 跳板机与目标各按自己那一跳。在信任库里删掉这台主机时也一起忘掉（`KnownHostLibrary.delete`）。
nonisolated final class LegacyAlgorithmGate: Sendable {
    enum Decision: Equatable, Sendable {
        /// 本机记着同意过，或第一次连 / 不核对主机密钥：照常连（记不记由连上之后的结果定）。
        case allow
        /// 以前连上过、没同意过旧算法：问用户。
        case ask
    }

    static func decide(consented: Bool, hasTrustRecord: Bool, verifiesHostKeys: Bool) -> Decision {
        if consented || !hasTrustRecord || !verifiesHostKeys { return .allow }
        return .ask
    }

    private let consent: LegacyAlgorithmConsent
    private let verifiesHostKeys: Bool
    private let hasTrustRecord: @Sendable (String, Int) async -> Bool
    private let approver: @Sendable (HostKeyChallenge) async -> Bool
    private let coalesces: Bool
    /// 这次连接里用户在弹层上亲手点了「取消」的那几跳（失败文案说「已取消」）。
    private let declinedByUser = Mutex<Set<LegacyAlgorithmConsent.Address>>([])

    /// - Parameters:
    ///   - approver: 问用户的出口，就是这条连接问主机密钥的那个（不能问的上下文它直接返回 false = 不同意）。
    ///   - interactive: `approver` 真的会问人时为 true：同一台主机同时在问的几条连接合并成一问
    ///     （`HostKeyApprovalCoalescer`）。不会问人的（命令行、Agent、收尾）不合并：它的「不」不能替正在弹框的标签答掉。
    ///
    /// 不自己限时：USSHKit 给钩子限时（`approvalTimeout`，到点按不同意），建连任务被取消时立即结束、钩子所在的任务
    /// 也被取消，relay 与合并器响应取消、撤掉弹层。
    init(consent: LegacyAlgorithmConsent = .shared,
         verifiesHostKeys: Bool,
         interactive: Bool,
         hasTrustRecord: @escaping @Sendable (String, Int) async -> Bool,
         approver: @escaping @Sendable (HostKeyChallenge) async -> Bool) {
        self.consent = consent
        self.verifiesHostKeys = verifiesHostKeys
        self.coalesces = interactive
        self.hasTrustRecord = hasTrustRecord
        self.approver = approver
    }

    convenience init(verifier: HostKeyVerifier,
                     hostKeyPolicy: USSHKit.SSHHostKeyPolicy,
                     interactive: Bool,
                     consent: LegacyAlgorithmConsent = .shared,
                     approver: @escaping @Sendable (HostKeyChallenge) async -> Bool) {
        self.init(consent: consent,
                  verifiesHostKeys: hostKeyPolicy != .insecureAcceptAll,
                  interactive: interactive,
                  hasTrustRecord: { host, port in await verifier.hasTrustRecord(host: host, port: port) },
                  approver: approver)
    }

    /// 交给 `USSHKitIntegration.connect(legacyFallbackApproval:)` 的那个闭包。
    var approval: @Sendable (SSHLegacyFallbackRequest) async -> Bool {
        { [self] request in
            await approve(host: request.host, port: request.port, isJumpHost: request.hop == .jumpHost)
        }
    }

    /// 某一跳要用旧算法了，同不同意。不记：记不记看连上之后的结果（`record`）。
    func approve(host: String, port: Int, isJumpHost: Bool) async -> Bool {
        let address = LegacyAlgorithmConsent.Address(host: host, port: port)
        let decision = Self.decide(consented: consent.contains(address),
                                   hasTrustRecord: await hasTrustRecord(host, port),
                                   verifiesHostKeys: verifiesHostKeys)
        guard decision == .ask else { return true }
        let challenge = HostKeyChallenge(host: host, port: port, kind: .weakAlgorithms,
                                         newFingerprint: "", oldFingerprint: nil, isJumpHost: isJumpHost)
        let approved = coalesces
            ? await HostKeyApprovalCoalescer.shared.approve(challenge, approver: approver)
            : await approver(challenge)
        if !approved, HostKeyUserDecline.take(challenge.id) { declinedByUser.withLock { _ = $0.insert(address) } }
        AppLogger.info("连接方式变弱的主机 \(address.key)：\(approved ? "用户同意用旧算法连接" : "没有同意，不连接")",
                       category: "ssh")
        return approved
    }

    /// 没连的那一跳是用户在弹层上亲手拒的：失败文案改说「已取消」（`LegacyAlgorithmRefusal.declinedByUser`）。
    func marked(_ refusal: LegacyAlgorithmRefusal) -> LegacyAlgorithmRefusal {
        var refusal = refusal
        let address = LegacyAlgorithmConsent.Address(host: refusal.host, port: refusal.port)
        refusal.declinedByUser = declinedByUser.withLock { $0.contains(address) }
        return refusal
    }

    /// 整条连接连上了（含认证）：按 USSHKit 报的每一跳的结果写同意。`true` 记、`false` 清、`nil` 不动。
    static func record(target: (host: String, port: Int, neededLegacy: Bool?),
                       jumpHost: (host: String, port: Int, neededLegacy: Bool?)?,
                       consent: LegacyAlgorithmConsent = .shared) {
        for hop in [jumpHost, target].compactMap({ $0 }) {
            switch hop.neededLegacy {
            case true?: consent.insert(host: hop.host, port: hop.port)
            case false?: consent.remove(host: hop.host, port: hop.port)
            case nil: break
            }
        }
    }

    /// 连上之后：按这次连接的每一跳与 USSHKit 的三态结果写进这个门的同意记录。
    ///
    /// 设置里关了主机密钥核对时对端是谁没有核实过：这次放行，但**不记**同意（`true` 当作 `nil`），否则恢复核对之后
    /// 这台会被当成「本来就只会旧算法」、再也不问。清（`false`）照常：那只会让之后多问一次。
    func connectionSucceeded(profile: SSHConnection.ProfileSnapshot, target: Bool?, jumpHost: Bool?) {
        let recordable: (Bool?) -> Bool? = { [verifiesHostKeys] in verifiesHostKeys || $0 != true ? $0 : nil }
        Self.record(target: (profile.host, profile.port, recordable(target)),
                    jumpHost: profile.jumpHost.map { ($0.host, $0.port, recordable(jumpHost)) },
                    consent: consent)
    }
}

/// 本机记着的「这台主机只能用旧算法连，同意过」（host:port 的集合）。
///
/// 只存本机的 UserDefaults（`DefaultsKey.sshLegacyAlgorithmHosts`），不进 iCloud / 局域网同步，也不进 `KnownHost`：
/// 给 `@Model` 加字段要手动部署 CloudKit 的生产 schema。测试宿主和正式版共用一份偏好，所以在测试宿主里改用
/// 单独的一份（`testHostSuiteName`），测试连真主机也不会往正式版的设置里写。
nonisolated struct LegacyAlgorithmConsent: Sendable {
    struct Address: Hashable, Sendable {
        let host: String
        let port: Int

        /// 主机名规整成小写、去掉首尾空白与 IPv6 的方括号：同一台换个写法（`Prod.Example.com`、`[fe80::1]`）
        /// 还是同一条记录。
        init(host: String, port: Int) {
            self.host = Self.normalized(host)
            self.port = port
        }

        static func normalized(_ host: String) -> String {
            var value = host.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("["), value.hasSuffix("]") { value = String(value.dropFirst().dropLast()) }
            return value.lowercased()
        }

        /// 存进偏好的写法。IPv6 地址加方括号，免得和端口混在一起。
        var key: String { SSHAddressText.format(host: host, port: port) }
    }

    static let testHostSuiteName = "com.uozi.uTerm.tests.legacyAlgorithmConsent"

    /// 生产用 `UserDefaults.standard`；测试宿主里用单独的一份。
    static var shared: LegacyAlgorithmConsent {
        LegacyAlgorithmConsent(suiteName: TestHostEnvironment.isActive ? testHostSuiteName : nil)
    }

    /// nil = `UserDefaults.standard`。
    let suiteName: String?

    /// 读改写之间别让两条连接互相覆盖。
    private static let lock = Mutex(())

    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    private var stored: [String] {
        defaults.stringArray(forKey: DefaultsKey.sshLegacyAlgorithmHosts) ?? []
    }

    func contains(_ address: Address) -> Bool {
        stored.contains(address.key)
    }

    func contains(host: String, port: Int) -> Bool {
        contains(Address(host: host, port: port))
    }

    func insert(_ address: Address) {
        Self.lock.withLock { _ in
            var hosts = stored
            guard !hosts.contains(address.key) else { return }
            hosts.append(address.key)
            defaults.set(hosts, forKey: DefaultsKey.sshLegacyAlgorithmHosts)
        }
    }

    func insert(host: String, port: Int) {
        insert(Address(host: host, port: port))
    }

    func remove(host: String, port: Int) {
        remove(Address(host: host, port: port))
    }

    func remove(_ address: Address) {
        let key = address.key
        Self.lock.withLock { _ in
            let hosts = stored
            guard hosts.contains(key) else { return }
            defaults.set(hosts.filter { $0 != key }, forKey: DefaultsKey.sshLegacyAlgorithmHosts)
        }
    }

    /// 测试用：清空。
    func removeAll() {
        Self.lock.withLock { _ in defaults.removeObject(forKey: DefaultsKey.sshLegacyAlgorithmHosts) }
    }
}

/// 没有同意用旧算法、所以没连的那一跳（`SSHConnection.SSHConnectionError.weakAlgorithmsDeclined`）。
nonisolated struct LegacyAlgorithmRefusal: Sendable, Equatable {
    let host: String
    let port: Int
    let isJumpHost: Bool
    /// 用户刚在弹层上点了「取消」（而不是没法问人的地方替他拒的）：文案只说已取消，不叫他回 uTerm 里再连一次。
    var declinedByUser = false

    init(host: String, port: Int, isJumpHost: Bool, declinedByUser: Bool = false) {
        self.host = host
        self.port = port
        self.isJumpHost = isJumpHost
        self.declinedByUser = declinedByUser
    }

    init(_ request: SSHLegacyFallbackRequest) {
        self.init(host: request.host, port: request.port, isJumpHost: request.hop == .jumpHost)
    }

    var address: String { SSHAddressText.format(host: host, port: port) }

    /// 连接失败时给人看的那句：说清是怎么回事、怎么办。不能问用户的地方（Agent、历史会话）也是这句。
    var message: String {
        if declinedByUser {
            return isJumpHost
                ? String(localized: "已取消连接：没有同意跳板机 \(address) 改用较旧、安全性较低的连接方式（SHA-1）。")
                : String(localized: "已取消连接 \(address)：没有同意改用较旧、安全性较低的连接方式（SHA-1）。")
        }
        return isJumpHost
            ? String(localized: "没有连接跳板机 \(address)：这台跳板机以前用更安全的连接方式，这次要改用较旧、安全性较低的连接方式（SHA-1）才能连上。要继续连接，请在 uTerm 里重新连接这台主机，在提示里选「仍然连接」。")
            : String(localized: "没有连接 \(address)：这台主机以前用更安全的连接方式，这次要改用较旧、安全性较低的连接方式（SHA-1）才能连上。要继续连接，请在 uTerm 里重新连接这台主机，在提示里选「仍然连接」。")
    }
}

/// 「连接方式变弱了」那一问的文案（Mac 的 `HostKeyPromptView`、iOS 的 `HostKeyTrustModal` 共用）。
/// 不出现 KEXINIT、hmac 这类词：说清以前怎样、这次怎样、可能是什么原因、选了会怎样。
nonisolated enum WeakAlgorithmsCopy {
    static func title(_ challenge: HostKeyChallenge) -> String {
        challenge.isJumpHost
            ? String(localized: "跳板机的连接方式变弱了")
            : String(localized: "这台主机的连接方式变弱了")
    }

    static func summary(_ challenge: HostKeyChallenge) -> String {
        let address = challenge.address
        return challenge.isJumpHost
            ? String(localized: "跳板机 \(address) 以前用更安全的连接方式，这次要改用较旧、安全性较低的连接方式（SHA-1）才能连上。")
            : String(localized: "\(address) 以前用更安全的连接方式，这次要改用较旧、安全性较低的连接方式（SHA-1）才能连上。")
    }

    static func advice(_ challenge: HostKeyChallenge) -> String {
        challenge.isJumpHost
            ? String(localized: "如果你最近没有调整过这台跳板机（比如重装系统、换了 SSH 服务），可能有人在中间拦截，建议先取消。选「仍然连接」后，这台设备上经这台跳板机的连接都不再询问；它又用回更安全的连接方式时，这个许可自动作废。")
            : String(localized: "如果你最近没有调整过这台服务器（比如重装系统、换了 SSH 服务），可能有人在中间拦截，建议先取消。选「仍然连接」后，这台设备上不再询问；它又用回更安全的连接方式时，这个许可自动作废。")
    }
}
