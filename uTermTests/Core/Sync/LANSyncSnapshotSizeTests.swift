import AgentKit
import XCTest
@testable import uTerm

/// 这些用例量的是快照编码后的真实字节数。
///
/// 历史背景：v1 是「整份快照 + 换行分帧」，单帧 512 KB 硬上限，实测 500 条消息就 771 KB——
/// 聊天用上一阵子，局域网同步就彻底不可用。v2 改成分片 + 长度前缀分帧后单帧只装
/// `chunkRecordLimit` 条记录，体积不再随库增长；这里留着读数，是为了记住为什么不能退回整份传输。
final class LANSyncSnapshotSizeTests: XCTestCase {
    private func encodedBytes(_ snapshot: LANSyncDataSnapshot) throws -> Int {
        // 与 LANSyncCoordinator 一致：默认配置的 JSONEncoder，紧凑输出。
        try JSONEncoder().encode(snapshot).count
    }

    /// 配置类数据（主机 / 分组 / 密钥 / 规则 / 命令），不含会话历史与运行留痕。
    private func configOnly(hosts: Int = 40, keys: Int = 8, rules: Int = 20,
                            commands: Int = 30) -> LANSyncDataSnapshot {
        LANSyncDataSnapshot(
            profiles: (0..<hosts).map {
                .init(id: UUID(), name: "生产环境 web-\($0)", host: "10.0.\($0 / 256).\($0 % 256)",
                      port: 22, username: "deploy", authMethodRaw: "privateKey", keyID: UUID(),
                      createdAt: Date(), sortOrder: $0, group: "production", isPinned: false,
                      lastConnectedAt: Date(), sftpOnly: false, jumpHostID: nil)
            },
            groups: (0..<6).map { .init(name: "group-\($0)", colorHex: "#9aa7b5",
                                        isPinned: false, sortOrder: $0) },
            knownHosts: (0..<hosts).map {
                .init(id: UUID(), host: "10.0.0.\($0)", port: 22, keyTypeRaw: "ssh-ed25519",
                      keyBlob: Data(repeating: 0x41, count: 80),
                      fingerprint: String(repeating: "a", count: 43), firstTrustedAt: Date())
            },
            sshKeys: (0..<keys).map {
                .init(id: UUID(), name: "key-\($0)", typeRaw: "ed25519", bits: 256,
                      comment: "deploy@mac", fingerprint: String(repeating: "b", count: 43),
                      publicKey: String(repeating: "c", count: 90), createdAt: Date(),
                      lastUsedAt: Date(), hasPassphrase: true)
            },
            providers: (0..<4).map {
                .init(id: UUID(), name: "provider-\($0)", kindRaw: "openai",
                      baseURL: "https://api.example.com/v1", model: "gpt-x",
                      sortOrder: $0, createdAt: Date())
            },
            forwardingRules: (0..<rules).map {
                .init(id: UUID(), serverID: UUID(), name: "rule-\($0)", typeRaw: "local",
                      listenHost: "127.0.0.1", listenPort: 5432 + $0, destHost: "db.internal",
                      destPort: 5432, destLabel: "PostgreSQL", autostart: true,
                      launchAtAppStart: true, sortOrder: $0, createdAt: Date())
            },
            quickCommands: (0..<commands).map {
                .init(id: UUID(), name: "cmd-\($0)", serverIDs: [UUID(), UUID()],
                      command: "systemctl status nginx && df -h", intent: "检查 nginx 与磁盘",
                      aiAssisted: true, lastRunAt: Date(), runCount: 12, sortOrder: $0,
                      createdAt: Date())
            },
            quickCommandRuns: [], chatSessions: [], chatMessages: [])
    }

    /// 在配置数据之上叠 N 条聊天消息。`text` 与 `displayText` 都落库，所以正文实际存两份。
    private func withChat(_ base: LANSyncDataSnapshot, messages: Int,
                          bytesPerMessage: Int) -> LANSyncDataSnapshot {
        let body = String(repeating: "内容", count: max(1, bytesPerMessage / 6))
        let sessionIDs = (0..<max(1, messages / 20)).map { _ in UUID() }
        return LANSyncDataSnapshot(
            profiles: base.profiles, groups: base.groups, knownHosts: base.knownHosts,
            sshKeys: base.sshKeys, providers: base.providers,
            forwardingRules: base.forwardingRules, quickCommands: base.quickCommands,
            quickCommandRuns: base.quickCommandRuns,
            chatSessions: sessionIDs.map {
                .init(id: $0, title: "会话", createdAt: Date(), updatedAt: Date(), scopeID: UUID())
            },
            chatMessages: (0..<messages).map { i in
                .init(id: UUID(), sessionID: sessionIDs[i % sessionIDs.count],
                      roleRaw: i.isMultiple(of: 2) ? "user" : "assistant", text: body,
                      createdAt: Date(), toolCallsJSON: "", toolCallID: "",
                      isError: false, displayText: body, orderIndex: i)
            })
    }

    func testConfigOnlySnapshotIsFarBelowTheTransportCap() throws {
        let bytes = try encodedBytes(configOnly())
        print("【量】纯配置（40 主机 / 8 密钥 / 20 规则 / 30 命令）: \(bytes) B")
        let heavy = try encodedBytes(configOnly(hosts: 200, keys: 30, rules: 80, commands: 120))
        print("【量】重度纯配置（200 主机 / 30 密钥 / 80 规则 / 120 命令）: \(heavy) B")
        XCTAssertLessThan(heavy, 512 * 1024,
                          "重度配置应当连 v1 的 512 KB 上限都不到，实际 \(heavy) B")
        XCTAssertLessThan(bytes, 128 * 1024, "纯配置数据应远低于任何上限，实际 \(bytes) B")
    }

    /// 记录 v1 的真实天花板：整份快照在聊天历史一多就越过当年 512 KB 的单帧上限，
    /// 越过即同步硬失败。这正是 v2 必须分片的原因，所以这里比的是**那个历史值**，
    /// 不是当前的 `maxFrameBytes`（后者已抬高，且有按字节细切兜着）。
    func testChatHistoryWouldHaveBlownTheLegacySingleFrameLimit() throws {
        let legacyCap = 512 * 1024
        let base = configOnly()
        var firstOverflow: Int?
        for count in [200, 500, 1_000, 2_000, 4_000] {
            let bytes = try encodedBytes(withChat(base, messages: count, bytesPerMessage: 600))
            let over = bytes > legacyCap
            print("【量】\(count) 条消息(每条约 600 B 正文): \(bytes) B\(over ? "  ← 越过 v1 的 512 KB 上限" : "")")
            if over, firstOverflow == nil { firstOverflow = count }
        }
        XCTAssertNotNil(firstOverflow,
                        "整份快照不再越过 v1 的 512 KB 上限，请重新评估分片策略是否还需要")
    }

    func testQuickCommandRunLogsAlsoWeighOnTheSnapshot() throws {
        let base = configOnly()
        let runs = (0..<90).map { _ in
            LANSyncDataSnapshot.QuickCommandRunRecord(
                id: UUID(), commandID: UUID(), startedAt: Date(), durationMs: 1_200,
                resultsJSON: String(repeating: "{\"host\":\"web\",\"ok\":true,\"out\":\"...\"},", count: 40),
                aiRecordJSON: nil)
        }
        let snapshot = LANSyncDataSnapshot(
            profiles: base.profiles, groups: base.groups, knownHosts: base.knownHosts,
            sshKeys: base.sshKeys, providers: base.providers,
            forwardingRules: base.forwardingRules, quickCommands: base.quickCommands,
            quickCommandRuns: runs, chatSessions: [], chatMessages: [])
        let bytes = try encodedBytes(snapshot)
        print("【量】配置 + 90 条运行留痕(每条约 1.6 KB 输出): \(bytes) B")

        // 多台广播时 resultsJSON 里装的是**每台**的命令输出，单条留痕可以到几十 KB。
        let wide = (0..<90).map { _ in
            LANSyncDataSnapshot.QuickCommandRunRecord(
                id: UUID(), commandID: UUID(), startedAt: Date(), durationMs: 1_200,
                resultsJSON: String(repeating: "{\"host\":\"web\",\"ok\":true,\"out\":\"...\"},",
                                    count: 500),
                aiRecordJSON: nil)
        }
        let wideSnapshot = LANSyncDataSnapshot(
            profiles: base.profiles, groups: base.groups, knownHosts: base.knownHosts,
            sshKeys: base.sshKeys, providers: base.providers,
            forwardingRules: base.forwardingRules, quickCommands: base.quickCommands,
            quickCommandRuns: wide, chatSessions: [], chatMessages: [])
        let wideBytes = try encodedBytes(wideSnapshot)
        print("【量】配置 + 90 条运行留痕(每条约 20 KB 输出): \(wideBytes) B"
              + (wideBytes > 512 * 1024 ? "  ← 越过 v1 的 512 KB 上限" : ""))
        XCTAssertGreaterThan(bytes, 0)
    }
}
