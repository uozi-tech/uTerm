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
/// | 否 | 否（第一次连） | — | 照常连，连上了记下同意（之后照常走新主机的信任确认） |
/// | 否 | — | 否（设置里关了核对） | 同上：中间人本来就能冒充它，问加密方式没有意义 |
/// | 否 | 是 | 是 | 问用户；同意了记下，之后不再问 |
///
/// 旧栈（Citadel + Wellz 的 swift-nio-ssh，SSH 栈换成 USSHKit 之前）**协商不到**这些旧算法：它只带 NIOSSH
/// 自带的 curve25519 / ECDH 密钥交换、ed25519 / ECDSA 主机密钥和 AES-GCM，Citadel 的 `ssh-rsa`、group14-sha1、
/// `hmac-sha1`（`SSHAlgorithms.all`）uTerm 从来没登记过。所以升级前写下的每一条 `KnownHost` 都是用现代算法连上的，
/// 不会因为升级被误问。会误问的只有一种：设备 A 第一次就用旧算法连上一台老设备（静默、只在 A 上记下同意），
/// 它的 `KnownHost` 经 iCloud 同步到设备 B，B 第一次连时会问一次（同意记在本机，不同步）。
///
/// 记下同意的时机：用户在提示里同意了，当场记；第一次连静默放行的，**连上之后**才记（`connectionSucceeded`）——
/// 主机密钥没被信任、认证失败，都不该留下「这台本来就只会旧算法」。从来不清掉：主机后来升级了，用不上旧算法，
/// 记着也不碍事；它再降回去也照旧不问（用户确认过「这台只能这样」）。在信任库里删掉这台主机时一起忘掉
/// （`KnownHostLibrary.delete`）。
nonisolated final class LegacyAlgorithmGate: Sendable {
    enum Decision: Equatable, Sendable {
        /// 本机记着同意过：照常连。
        case allow
        /// 第一次连（或不核对主机密钥）：照常连，连上之后记下同意。
        case allowAndRemember
        /// 以前连上过、没同意过旧算法：问用户。
        case ask
    }

    static func decide(consented: Bool, hasTrustRecord: Bool, verifiesHostKeys: Bool) -> Decision {
        if consented { return .allow }
        if !hasTrustRecord || !verifiesHostKeys { return .allowAndRemember }
        return .ask
    }

    private let consent: LegacyAlgorithmConsent
    private let verifiesHostKeys: Bool
    private let hasTrustRecord: @Sendable (String, Int) async -> Bool
    private let approver: @Sendable (HostKeyChallenge) async -> Bool
    private let coalesces: Bool
    /// 静默放行、等连上之后再记下同意的那几跳。
    private let pending = Mutex<Set<LegacyAlgorithmConsent.Address>>([])

    /// - Parameters:
    ///   - approver: 问用户的出口，就是这条连接问主机密钥的那个（不能问的上下文它直接返回 false = 不同意）。
    ///   - interactive: `approver` 真的会问人时为 true：同一台主机同时在问的几条连接合并成一问
    ///     （`HostKeyApprovalCoalescer`）。不会问人的（命令行、Agent、收尾）不合并：它的「不」不能替正在弹框的标签答掉。
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

    /// 某一跳要用旧算法了，同不同意。
    func approve(host: String, port: Int, isJumpHost: Bool) async -> Bool {
        let address = LegacyAlgorithmConsent.Address(host: host, port: port)
        let decision = Self.decide(consented: consent.contains(address),
                                   hasTrustRecord: await hasTrustRecord(host, port),
                                   verifiesHostKeys: verifiesHostKeys)
        switch decision {
        case .allow:
            return true
        case .allowAndRemember:
            pending.withLock { _ = $0.insert(address) }
            return true
        case .ask:
            let challenge = HostKeyChallenge(host: host, port: port, kind: .weakAlgorithms,
                                             newFingerprint: "", oldFingerprint: nil, isJumpHost: isJumpHost)
            let approved = coalesces
                ? await HostKeyApprovalCoalescer.shared.approve(challenge, approver: approver)
                : await approver(challenge)
            if approved { consent.insert(address) }
            AppLogger.info("加密方式变弱的主机 \(address.key)：\(approved ? "用户同意用旧算法连接" : "没有同意，不连接")",
                           category: "ssh")
            return approved
        }
    }

    /// 整条连接连上了：把静默放行的那几跳记成「本来就只会旧算法」。
    func connectionSucceeded() {
        let addresses = pending.withLock { taken -> Set<LegacyAlgorithmConsent.Address> in
            defer { taken = [] }
            return taken
        }
        for address in addresses { consent.insert(address) }
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

        /// 存进偏好的写法。IPv6 地址加方括号，免得和端口混在一起。
        var key: String {
            host.contains(":") ? "[\(host)]:\(String(port))" : "\(host):\(String(port))"
        }
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
        let key = Address(host: host, port: port).key
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

    init(host: String, port: Int, isJumpHost: Bool) {
        self.host = host
        self.port = port
        self.isJumpHost = isJumpHost
    }

    init(_ request: SSHLegacyFallbackRequest) {
        self.init(host: request.host, port: request.port, isJumpHost: request.hop == .jumpHost)
    }

    var address: String { "\(host):\(String(port))" }

    /// 连接失败时给人看的那句：说清是怎么回事、怎么办。不能问用户的地方（Agent、历史会话）也是这句。
    var message: String {
        isJumpHost
            ? String(localized: "没有连接跳板机 \(address)：这台跳板机以前用较新的加密方式连接，这次只提供较旧、安全性较低的方式（SHA-1）。要继续用这种方式，请在 uTerm 里重新连接这台主机，在提示里选「仍然连接」。")
            : String(localized: "没有连接 \(address)：这台主机以前用较新的加密方式连接，这次只提供较旧、安全性较低的方式（SHA-1）。要继续用这种方式，请在 uTerm 里重新连接这台主机，在提示里选「仍然连接」。")
    }
}

/// 「加密方式变弱了」那一问的文案（Mac 的 `HostKeyPromptView`、iOS 的 `HostKeyTrustModal` 共用）。
/// 不出现 KEXINIT、hmac 这类词：说清以前怎样、这次怎样、可能是什么原因、选了会怎样。
nonisolated enum WeakAlgorithmsCopy {
    static func title(_ challenge: HostKeyChallenge) -> String {
        challenge.isJumpHost
            ? String(localized: "跳板机的加密方式变弱了")
            : String(localized: "这台主机的加密方式变弱了")
    }

    static func summary(_ challenge: HostKeyChallenge) -> String {
        let address = "\(challenge.host):\(String(challenge.port))"
        return challenge.isJumpHost
            ? String(localized: "跳板机 \(address) 以前用较新的加密方式连接，这次只提供较旧的方式（SHA-1），安全性较低。")
            : String(localized: "\(address) 以前用较新的加密方式连接，这次服务器只提供较旧的方式（SHA-1），安全性较低。")
    }

    static var advice: String {
        String(localized: "如果你最近没有调整过这台服务器（比如重装系统、换了 SSH 服务），可能有人在中间拦截，建议先取消。选「仍然连接」后，以后连接它不再询问。")
    }
}
