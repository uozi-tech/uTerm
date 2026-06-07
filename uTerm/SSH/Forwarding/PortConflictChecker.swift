import Foundation

/// 端口转发的纯逻辑校验：同侧冲突检测、空闲端口建议、特权端口判定。零 SSH、零 SwiftData。
/// `nonisolated` —— 可在任意上下文（视图实时校验、actor）调用。
nonisolated enum PortConflictChecker {

    /// 知名端口表（监听这些口大概率撞系统服务）。
    static let wellKnownPorts: [Int: String] = [22: "SSH", 631: "CUPS", 5000: "AirPlay"]

    /// 一次冲突的描述：被哪个端口、被谁（其它规则名 / 系统服务名）占用。
    struct Conflict: Equatable, Sendable {
        let port: Int
        let occupant: String
    }

    /// 两种转发是否绑定同一侧（决定端口是否真会互撞）。
    /// local/dynamic 在**本地**侧监听，remote 在**远端**侧监听。
    static func sameSide(_ a: ForwardKind, _ b: ForwardKind) -> Bool {
        bindsRemoteSide(a) == bindsRemoteSide(b)
    }

    /// remote 在远端绑定监听口；local/dynamic 在本地绑定。
    private static func bindsRemoteSide(_ kind: ForwardKind) -> Bool {
        kind == .remote
    }

    /// 检测 `listenPort` 是否与同侧的其它规则、或知名端口冲突。
    /// `excluding` 用于编辑场景排除规则自身。规则冲突优先于知名端口（更可操作）。
    static func conflict(kind: ForwardKind, listenPort: Int,
                         excluding ruleID: UUID?,
                         against rules: [ForwardingRuleSnapshot]) -> Conflict? {
        // 1) 同侧规则占用（排除自身）
        if let clash = rules.first(where: { r in
            r.id != ruleID
                && r.listenPort == listenPort
                && sameSide(kind, r.kind)
        }) {
            return Conflict(port: listenPort, occupant: clash.name)
        }
        // 2) 知名端口（仅本地绑定侧；remote 规则监听的是远端主机的端口，与本地系统服务无关）
        if !bindsRemoteSide(kind), let service = wellKnownPorts[listenPort] {
            return Conflict(port: listenPort, occupant: service)
        }
        return nil
    }

    /// 从 `port` 起向上找第一个同侧不冲突、也非知名端口的端口。
    /// 上界封顶 65535；找不到返回 `port`（调用方据现有冲突自行兜底）。
    static func suggestFreePort(after port: Int, kind: ForwardKind,
                                against rules: [ForwardingRuleSnapshot]) -> Int {
        var candidate = port + 1
        while candidate <= 65535 {
            if conflict(kind: kind, listenPort: candidate, excluding: nil, against: rules) == nil {
                return candidate
            }
            candidate += 1
        }
        return port
    }

    /// 特权端口警告判定：`<1024` 且当前无冲突（已冲突则不叠加二次提示）。
    static func isPrivileged(_ port: Int, hasConflict: Bool) -> Bool {
        port < 1024 && !hasConflict
    }
}
