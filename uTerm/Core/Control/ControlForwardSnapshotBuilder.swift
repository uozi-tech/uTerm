import Foundation
import Darwin

/// 转发组（`forward-*`）的纯逻辑：规则解析、线上形状构造、本机端口占用探测。
///
/// 三块都不碰 SwiftData / 网络会话，`ControlForwardHandlerTests` 直接断言。

// MARK: - 规则解析

/// 规则名 / UUID → 规则 id 的四级解析。**与主机解析同构**（精确 → 忽略大小写 →
/// 唯一前缀），但刻意不复用 `HostResolver` —— 两者的候选类型与歧义载荷不同，
/// 强行共用只会把两边的规则绑死。
nonisolated enum ControlForwardRuleResolver {

    /// 一条候选规则的轻量元组（不吃 `@Model`：它既非 `Sendable` 也不便造夹具）。
    struct Candidate: Sendable, Equatable {
        let id: UUID
        let name: String

        init(id: UUID, name: String) {
            self.id = id
            self.name = name
        }
    }

    enum Outcome: Sendable, Equatable {
        case matched(UUID)
        /// 同一级命中多条 —— 回 `rule_ambiguous`，并把候选（带 UUID）交给 CLI。
        case ambiguous([Candidate])
        case notFound
    }

    static func resolve(_ needle: String, in candidates: [Candidate]) -> Outcome {
        let trimmed = needle.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .notFound }

        // 1) UUID 直达。
        if let uuid = UUID(uuidString: trimmed) {
            if candidates.contains(where: { $0.id == uuid }) { return .matched(uuid) }
            return .notFound
        }

        // 2) 精确 → 3) 忽略大小写 → 4) 前缀（忽略大小写）。逐级短路。
        let lowered = trimmed.lowercased()
        let levels: [[Candidate]] = [
            candidates.filter { $0.name == trimmed },
            candidates.filter { $0.name.lowercased() == lowered },
            candidates.filter { $0.name.lowercased().hasPrefix(lowered) }
        ]
        for level in levels {
            if level.count == 1 { return .matched(level[0].id) }
            if level.count > 1 { return .ambiguous(level) }
        }
        return .notFound
    }
}

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
