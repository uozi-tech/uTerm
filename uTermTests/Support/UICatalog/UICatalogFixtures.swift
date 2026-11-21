import Foundation
import SwiftData
@testable import uTerm

/// 画廊的夹具数据：几组主机、密钥、转发规则、快捷命令。地址一律用保留网段 / example 域名。
@MainActor
enum UICatalogFixtures {
    /// 固定的「现在」：相对时间（「3 分钟前」）每次出图都一样，前后两轮才比得了。
    nonisolated static let now = Date(timeIntervalSince1970: 1_795_180_000)

    static func seed(_ s: UICatalogStage.Session) {
        let ctx = s.context
        let groups: [(String, String)] = [("生产", "#ef4444"), ("测试", "#3b82f6"), ("家里", "#a855f7")]
        for (i, (name, color)) in groups.enumerated() {
            let g = ServerGroup(name: name, colorHex: color, isPinned: i == 0, sortOrder: i)
            ctx.insert(g)
            s.groups[name] = g
        }

        let key = SSHKey()
        key.name = "macbook-2026"
        key.typeRaw = SSHKeyKind.ed25519.rawValue
        key.bits = 256
        key.comment = "deploy@macbook"
        key.fingerprint = "SHA256:Qm4bXo2Lk3T0w8V1sN7cHf9eRZy6aJd5uPq2gKtW4E"
        key.publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIK3m0h7y4Qp8sV2bN6cXo1fR9tLz5aJd3uPq2gKtW4E deploy@macbook"
        key.createdAt = now.addingTimeInterval(-86_400 * 120)
        key.lastUsedAt = now.addingTimeInterval(-600)
        ctx.insert(key)
        let rsa = SSHKey()
        rsa.name = "legacy-ops"
        rsa.typeRaw = SSHKeyKind.rsa.rawValue
        rsa.bits = 4096
        rsa.comment = "ops@legacy"
        rsa.fingerprint = "SHA256:7dF2kq9XbR0vN3sL8wJ1mT6cY4hP5aZ2eU0iO7gB1Qs"
        rsa.publicKey = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQC… ops@legacy"
        rsa.createdAt = now.addingTimeInterval(-86_400 * 700)
        rsa.hasPassphrase = true
        ctx.insert(rsa)

        let bastion = profile("bastion", "203.0.113.10", "ops", group: "生产", order: 0, lastUsed: -3_600)
        let rows: [(String, String, String, String?, Double?)] = [
            ("prod-web-01", "10.0.1.11", "deploy", "生产", -180),
            ("prod-web-02", "10.0.1.12", "deploy", "生产", -7_200),
            ("prod-db", "10.0.2.21", "postgres", "生产", -86_400),
            ("staging", "staging.example.com", "deploy", "测试", -1_800),
            ("k3s-lab", "192.168.10.30", "ubuntu", "测试", -86_400 * 3),
            ("nas", "192.168.1.5", "admin", "家里", -86_400 * 9),
            ("raspberry-pi", "192.168.1.42", "pi", "家里", nil),
        ]
        s.hosts["bastion"] = bastion
        ctx.insert(bastion)
        for (i, r) in rows.enumerated() {
            let p = profile(r.0, r.1, r.2, group: r.3, order: i + 1, lastUsed: r.4)
            p.keyID = key.id
            p.authMethodRaw = AuthMethod.privateKey.rawValue
            if r.0 == "prod-db" { p.jumpHost = bastion }
            ctx.insert(p)
            s.hosts[r.0] = p
        }

        let rules: [(String, ForwardKind, Int, String?, Int, Bool)] = [
            ("pg", .local, 15432, "10.0.2.21", 5432, false),
            ("grafana", .local, 3000, "127.0.0.1", 3000, false),
            ("dev-preview", .remote, 8080, "127.0.0.1", 5173, false),
            ("socks", .dynamic, 1080, nil, 0, false),
        ]
        for r in rules {
            let rule = ForwardingRule()
            rule.serverID = r.0 == "dev-preview" ? s.host("staging").id : (r.0 == "socks" ? bastion.id : s.host("prod-db").id)
            rule.name = r.0
            rule.typeRaw = r.1.rawValue
            rule.listenPort = r.2
            rule.destHost = r.3
            rule.destPort = r.4
            rule.autostart = r.5
            ctx.insert(rule)
        }

        let web = [s.host("prod-web-01").id, s.host("prod-web-02").id]
        let all = web + [s.host("prod-db").id, s.host("staging").id, s.host("k3s-lab").id, s.host("nas").id]
        let commands = [
            QuickCommand(name: "磁盘水位", serverIDs: all, command: "df -h / | tail -1", sortOrder: 0,
                         createdAt: now.addingTimeInterval(-86_400 * 30)),
            QuickCommand(name: "重新加载 nginx", serverIDs: web, command: "sudo nginx -t && sudo systemctl reload nginx",
                         sortOrder: 1, createdAt: now.addingTimeInterval(-86_400 * 20)),
            QuickCommand(name: "排查 502", serverIDs: web, command: "",
                         intent: "看 nginx 错误日志和上游进程，找出 502 的原因", aiAssisted: true, sortOrder: 2,
                         createdAt: now.addingTimeInterval(-86_400 * 7)),
            QuickCommand(name: "容器状态", serverIDs: [s.host("k3s-lab").id, s.host("staging").id],
                         command: "docker ps --format 'table {{.Names}}\\t{{.Status}}'", sortOrder: 3,
                         createdAt: now.addingTimeInterval(-86_400 * 3)),
        ]
        commands[0].lastRunAt = now.addingTimeInterval(-900); commands[0].runCount = 42
        commands[1].lastRunAt = now.addingTimeInterval(-86_400); commands[1].runCount = 9
        commands[2].lastRunAt = now.addingTimeInterval(-3_600 * 5); commands[2].runCount = 3
        for c in commands { ctx.insert(c) }
        s.commands = commands

        let run = QuickCommandRun()
        run.commandID = commands[0].id
        run.startedAt = now.addingTimeInterval(-900)
        run.durationMs = 1_480
        run.results = all.compactMap { id in
            guard let p = s.hosts.values.first(where: { $0.id == id }) else { return nil }
            return QuickCommandServerResult(serverID: id, serverName: p.name,
                                            endpoint: "\(p.username)@\(p.host):\(p.port)",
                                            exitCode: 0, durationMs: 600 + p.sortOrder * 97, ok: true)
        }
        ctx.insert(run)
    }

    private static func profile(_ name: String, _ host: String, _ user: String, group: String?,
                                order: Int, lastUsed: Double?) -> ServerProfile {
        let p = ServerProfile()
        p.name = name
        p.host = host
        p.username = user
        p.group = group
        p.sortOrder = order
        p.lastConnectedAt = lastUsed.map { now.addingTimeInterval($0) }
        return p
    }
}
