import Foundation
import Darwin

/// 转发组（`forward-*`）的纯逻辑：线上形状构造与本机端口占用探测。
///
/// 两块都不碰 SwiftData / 网络会话，`ControlForwardHandlerTests` 直接断言。
/// 规则名 / UUID 的解析**不在这里** —— 它与主机解析同构，直接用 `HostResolver`
/// （`ControlHandler+Forward.resolveRule` 只负责把 outcome 翻成 `rule_*` 错误码）。

// MARK: - 线上形状

nonisolated enum ControlForwardSnapshotBuilder {

    /// `TunnelStatus` → 协议里的四态字符串。
    static func statusText(_ status: TunnelStatus) -> String {
        switch status {
        case .inactive: return "inactive"
        case .starting: return "starting"
        case .active: return "active"
        case .error: return "error"
        }
    }

    /// `issue`：`error` 态取分类后的失败文案；`active` 态取「最近一次单连接失败」。
    static func issueText(status: TunnelStatus, connectionIssue: String?) -> String? {
        if case .error(let failure) = status { return failure.message }
        return connectionIssue
    }

    static func make(
        rule: ForwardingRuleSnapshot,
        serverName: String,
        status: TunnelStatus,
        connectionIssue: String? = nil,
        bytes: TunnelBytes? = nil
    ) -> ControlForwardSnapshot {
        ControlForwardSnapshot(
            id: rule.id.uuidString,
            serverID: rule.serverID.uuidString,
            serverName: serverName,
            name: rule.name,
            kind: rule.kind.rawValue,
            listenHost: rule.listenHost,
            listenPort: rule.listenPort,
            destHost: rule.kind == .dynamic ? nil : rule.destHost,
            destPort: rule.destPort,
            autostart: rule.autostart,
            status: statusText(status),
            issue: issueText(status: status, connectionIssue: connectionIssue),
            // 上行 = 本地→远端 = 出；下行 = 远端→本地 = 入。
            bytesIn: bytes?.down,
            bytesOut: bytes?.up
        )
    }
}

// MARK: - 本机端口占用探测

/// 真绑一下再放开：`PortConflictChecker` 只看**规则之间**与知名端口，看不见
/// 「别的进程已经占着这个口」。`forward-start` 在把请求交给 NIO 之前先探一次，
/// 让端口占用变成明确的 `port_in_use`，而不是冒成通用的转发失败。
///
/// 只探本地绑定侧（`-L` / `-D`）；`-R` 的监听口开在远端，本机探不到。
nonisolated enum ControlLocalPortProbe {

    /// `true` = 该地址端口已被占用（bind 得到 `EADDRINUSE`）。
    ///
    /// 刻意**不设** `SO_REUSEADDR`：设了之后 TIME_WAIT 的旧连接不再算占用，
    /// 但我们要的正是「有没有人正在监听」这个判断。非 IPv4 字面量（主机名 / IPv6）
    /// 探不了，一律返回 `false`（交给真正的 bind 报错），不猜。
    static func isBusy(host: String, port: Int) -> Bool {
        guard port > 0, port <= 65_535 else { return false }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        let target = host.isEmpty ? "0.0.0.0" : host
        guard inet_pton(AF_INET, target, &addr.sin_addr) == 1 else { return false }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { _ = Darwin.close(fd) }

        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                Darwin.bind(fd, raw, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 { return false }
        return errno == EADDRINUSE
    }
}
