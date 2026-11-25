import AgentKit
import AppKit
import SwiftData
import SwiftUI
@testable import uTerm

/// 独立的管理窗口：密钥、分组、已知主机、导入、端口转发、并行执行、授权引导。
@MainActor
extension UICatalog {
    static var tools: [UICatalogEntry] {
        let mid = CGSize(width: 1000, height: 660)
        return [
            // 独立的 SFTP 窗口（「在 SFTP 中打开」）：两个标签，接的都是假 SFTP。
            UICatalogEntry("SFTP 窗口", source: "uTerm/Features/SFTP/Views/SFTPWindowView.swift",
                           symbol: "SFTPWindowView", size: CGSize(width: 1120, height: 720)) { stage in
                let s = try stage.session()
                let server = s.host("prod-web-01")
                var tabs: [SFTPBrowserTab] = []
                for path in ["/etc/nginx", "/home/deploy"] {
                    let sftp = MockSFTP(tree: UICatalogFiles.tree)
                    let model = FileBrowserModel(testProvider: sftp, startPath: path, resolvesOwnerNames: false)
                    await model.load(path)
                    tabs.append(SFTPBrowserTab(model: model))
                }
                let view = s.wrap(SFTPWindowView(windowID: SFTPWindowID(id: UUID(), serverID: server.id), catalogTabs: tabs))
                return UICatalogRender(view, cleanup: { tabs.forEach { $0.model.dispose() } })
            },
            // 信任过的主机这次只肯用 SHA-1 时代的旧算法：连之前问（`LegacyAlgorithmGate`）。直连与跳板机各一张。
            UICatalogEntry("连接确认/连接方式变弱了", .sheet, source: "uTerm/Shared/Views/HostKeyPromptView.swift",
                           symbol: "HostKeyPromptView", size: CGSize(width: 460, height: 260)) { stage in
                let s = try stage.session()
                let challenge = HostKeyChallenge(host: "prod-web-01.example.com", port: 22, kind: .weakAlgorithms,
                                                 newFingerprint: "", oldFingerprint: nil)
                // 真的弹层里背景是 sheet 窗口给的，这里补上，不然深色图是白底白字。
                return UICatalogRender(s.wrap(HostKeyPromptView(challenge: challenge) { _ in }
                    .background(Color(nsColor: .windowBackgroundColor))))
            },
            UICatalogEntry("连接确认/连接方式变弱了 · 跳板机", .sheet, source: "uTerm/Shared/Views/HostKeyPromptView.swift",
                           symbol: "HostKeyPromptView", size: CGSize(width: 460, height: 260)) { stage in
                let s = try stage.session()
                let challenge = HostKeyChallenge(host: "bastion.example.com", port: 2222, kind: .weakAlgorithms,
                                                 newFingerprint: "", oldFingerprint: nil, isJumpHost: true)
                // 真的弹层里背景是 sheet 窗口给的，这里补上，不然深色图是白底白字。
                return UICatalogRender(s.wrap(HostKeyPromptView(challenge: challenge) { _ in }
                    .background(Color(nsColor: .windowBackgroundColor))))
            },
            UICatalogEntry("密钥管理", source: "uTerm/Features/Keys/Views/KeyManagerView.swift",
                           symbol: "KeyManagerView", size: mid) { stage in
                let s = try stage.session()
                return UICatalogRender(s.wrap(KeyManagerView()))
            },
            UICatalogEntry("分组管理", source: "uTerm/Features/Groups/Views/GroupsManagerView.swift",
                           symbol: "GroupsManagerView", size: mid) { stage in
                let s = try stage.session()
                return UICatalogRender(s.wrap(GroupsManagerView()))
            },
            UICatalogEntry("已知主机指纹", source: "uTerm/Features/Security/Views/KnownHostsManagerView.swift",
                           symbol: "KnownHostsManagerView", size: mid) { stage in
                let s = try stage.session()
                seedKnownHosts(s)
                return UICatalogRender(s.wrap(KnownHostsManagerView()))
            },
            UICatalogEntry("导入 SSH 配置", source: "uTerm/Features/Import/Views/SSHConfigImportView.swift",
                           symbol: "SSHConfigImportView", size: mid) { stage in
                let s = try stage.session()
                return UICatalogRender(s.wrap(SSHConfigImportView()))
            },
            UICatalogEntry("端口转发/单台主机", source: "uTerm/Features/PortForward/Views/PortForwardWindowView.swift",
                           symbol: "PortForwardWindowView", size: mid) { stage in
                let s = try stage.session()
                let id = PortForwardWindowID(id: UUID(), serverID: s.host("prod-db").id)
                return UICatalogRender(s.wrap(PortForwardWindowView(windowID: id)))
            },
            UICatalogEntry("端口转发/全局", source: "uTerm/Features/PortForward/Global/GlobalForwardingWindowView.swift",
                           symbol: "GlobalForwardingWindowView", size: mid) { stage in
                let s = try stage.session()
                return UICatalogRender(s.wrap(GlobalForwardingWindowView()))
            },
            UICatalogEntry("并行执行/命令", source: "uTerm/Features/ParallelRun/Views/ParallelRunWindowView.swift",
                           symbol: "ParallelRunWindowView", size: CGSize(width: 1180, height: 760)) { stage in
                try parallelRender(stage, command: 0)
            },
            UICatalogEntry("并行执行/AI 排查", source: "uTerm/Features/ParallelRun/Views/ParallelAgentView.swift",
                           symbol: "ParallelAgentView", size: CGSize(width: 1180, height: 760)) { stage in
                try parallelRender(stage, command: 2)
            },
            // Claude 历史会话：假的 ~/.claude/projects（MockSFTP），三条命令行会话 + 一条桌面版（不列出）。
            UICatalogEntry("Claude 历史会话", source: "uTerm/Features/ClaudeHistory/Views/ClaudeHistoryWindow.swift",
                           symbol: "ClaudeHistoryWindowView", size: CGSize(width: 1100, height: 720)) { stage in
                let s = try stage.session()
                let server = s.host("prod-web-01")
                let history = await UICatalogClaudeHistory.model()
                let windowID = ClaudeHistoryWindowID(host: .server(server.id), directory: UICatalogClaudeHistory.directory)
                let window = ClaudeHistoryWindowModel(windowID: windowID, hostName: server.name, history: history)
                return UICatalogRender(s.wrap(ClaudeHistoryWindowView(windowID: windowID, catalogModel: window)))
            },
            // 派了子代理的对话：调用下面有「查看子代理的记录」的入口。
            UICatalogEntry("Claude 历史会话/子代理入口", source: "uTerm/Features/ClaudeHistory/Views/AgentHistoryBrowser.swift",
                           symbol: "AgentSubagentEntry", size: CGSize(width: 1100, height: 720)) { stage in
                try await claudeHistoryRender(stage, opening: .subagents)
            },
            // 会话还开着：标题旁「正在更新」，往上翻着时末尾来了新内容，底部「有新消息」。
            // 往上翻用的是真的滚轮事件，窗口要在屏上（`live`）才收得到。
            UICatalogEntry("Claude 历史会话/实时跟随", source: "uTerm/Features/ClaudeHistory/Views/AgentHistoryBrowser.swift",
                           symbol: "AgentNewMessagesPill", size: CGSize(width: 1100, height: 720),
                           live: true) { stage in
                try await claudeHistoryRender(stage, opening: .live)
            },
            // 点进一个子代理：标题处是它的描述与类型，左上角返回上一层；它又派了一个子代理，同样有入口。
            UICatalogEntry("Claude 历史会话/子代理的记录", source: "uTerm/Features/ClaudeHistory/Views/AgentHistoryBrowser.swift",
                           symbol: "AgentTranscriptPane", size: CGSize(width: 1100, height: 720)) { stage in
                try await claudeHistoryRender(stage, opening: .subagentTranscript)
            },
            // 搜索：列表顶上搜「订单」，结果按会话分组（谁说的 + 前后文，命中的字加粗着色）。
            UICatalogEntry("Claude 历史会话/搜索结果", source: "uTerm/Features/ClaudeHistory/Views/AgentHistoryBrowser.swift",
                           symbol: "AgentHistorySearchResults", size: CGSize(width: 1100, height: 720)) { stage in
                try await claudeHistoryRender(stage, opening: .search)
            },
            // 点开一条命中：对话停在那一条上（整条底色 + 左边一道线），顶上「跳到最新」，底下「加载更晚的消息」。
            UICatalogEntry("Claude 历史会话/从命中处打开", source: "uTerm/Features/ClaudeHistory/Views/AgentHistoryBrowser.swift",
                           symbol: "AgentTranscriptPane", size: CGSize(width: 1100, height: 720)) { stage in
                try await claudeHistoryRender(stage, opening: .searchHit)
            },
            UICatalogEntry("授权引导", source: "uTerm/Features/PermissionGuide/PermissionGuideView.swift",
                           symbol: "PermissionGuideView", size: CGSize(width: 760, height: 640)) { stage in
                let s = try stage.session()
                return UICatalogRender(s.wrap(PermissionGuideView()))
            },
        ]
    }

    private static func seedKnownHosts(_ s: UICatalogStage.Session) {
        let hosts: [(String, Int, String, String)] = [
            ("10.0.1.11", 22, "ssh-ed25519", "SHA256:q3H8Pc0q1yUuR6m0uZx4p5wB2nK9vD7sL1aT0eF3gHk"),
            ("10.0.1.12", 22, "ssh-ed25519", "SHA256:Zb4XyQ0mN8kR2tV6wH1cP9sD5fG3jL7aE0uI4oY2rTx"),
            ("203.0.113.10", 22, "ecdsa-sha2-nistp256", "SHA256:Lm2Nq5Rs8Tv1Wx4Yz7Ab0Cd3Ef6Gh9Ij2Kl5Mn8Op1Q"),
            ("staging.example.com", 22, "rsa-sha2-512", "SHA256:Ht6Yc3Vb9Nm2Lk5Jh8Gf1Ds4Ap7Oi0Uy3Tr6Ew9Qz2X"),
        ]
        for (i, h) in hosts.enumerated() {
            let host = KnownHost()
            host.host = h.0
            host.port = h.1
            host.keyTypeRaw = h.2
            host.fingerprint = h.3
            host.firstTrustedAt = UICatalogFixtures.now.addingTimeInterval(-Double(i + 1) * 86_400 * 11)
            s.context.insert(host)
        }
        try? s.context.save()
    }

    private static func claudeHistoryRender(_ stage: UICatalogStage,
                                            opening: UICatalogClaudeHistory.Opening) async throws -> UICatalogRender {
        let s = try stage.session()
        let server = s.host("prod-web-01")
        let history = await UICatalogClaudeHistory.model(opening: opening)
        let windowID = ClaudeHistoryWindowID(host: .server(server.id), directory: UICatalogClaudeHistory.directory)
        let window = ClaudeHistoryWindowModel(windowID: windowID, hostName: server.name, history: history)
        let view = s.wrap(ClaudeHistoryWindowView(windowID: windowID, catalogModel: window))
        guard opening == .live else { return UICatalogRender(view) }
        // 用户往上翻着（真的滚轮事件），末尾来了新内容：位置不动，底部亮「有新消息」。
        return UICatalogRender(view, after: { root in
            guard let scroll = root.firstScrollView() else { return }
            try? await scroll.simulateTrackpadScroll(up: 360)
            try? await Task.sleep(for: .milliseconds(400))
            await UICatalogClaudeHistory.appendLiveTurn(history)
            try? await Task.sleep(for: .milliseconds(400))
            try? await Task.sleep(for: .milliseconds(400))
        })
    }

    private static func parallelRender(_ stage: UICatalogStage, command index: Int) throws -> UICatalogRender {
        let s = try stage.session()
        let command = s.commands[index]
        let targets = command.serverIDs.compactMap { id in s.hosts.values.first { $0.id == id } }
        let model = ParallelRunModel(commandID: command.id, commandName: command.name, command: command.command,
                                     intent: command.intent, aiAssisted: command.aiAssisted, targets: targets,
                                     doctor: command.aiAssisted ? scriptedDoctor() : nil,
                                     approval: .safety(.readAuto), hostLabel: "macOS 原生 SSH 终端",
                                     store: QuickCommandStore(context: s.context), container: s.container,
                                     executor: UICatalogParallelExecutor())
        let view = s.wrap(ParallelRunWindowView(windowID: ParallelRunWindowID(commandID: command.id),
                                                catalogModel: model))
        return UICatalogRender(view, after: { _ in
            model.start()
            for _ in 0..<40 where !model.allDone { try? await Task.sleep(for: .milliseconds(100)) }
        }, cleanup: { model.cancel() })
    }

    /// AI 排查用的脚本化模型：每台先跑两条只读命令，再给结论；最后一段是汇总。
    /// `MockLLMClient` 按调用顺序出列，两台并发时顺序可能交错，所以前后段都放成「同类」的。
    private static func scriptedDoctor() -> ParallelAIDoctor {
        func call(_ command: String) -> LLMEvent {
            let args = (try? JSONSerialization.data(withJSONObject: ["command": command]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            return .toolCall(LLMToolCall(id: UUID().uuidString, name: "run_command", argumentsJSON: args))
        }
        let verdict = #"{"status":"ok","summary":"上游 127.0.0.1:8080 在 21:02 拒绝连接：java 进程因内存不足被内核杀掉，重启前的请求全部 502。"}"#
        let llm = MockLLMClient(scripts: [
            [.text("先看 nginx 的错误日志。"), call("tail -n 2 /var/log/nginx/error.log")],
            [.text("先看 nginx 的错误日志。"), call("tail -n 2 /var/log/nginx/error.log")],
            [.text("上游拒绝连接，看看进程是不是被杀了。"), call("journalctl -k --since '1 hour ago' | grep -i oom")],
            [.text("上游拒绝连接，看看进程是不是被杀了。"), call("journalctl -k --since '1 hour ago' | grep -i oom")],
            [.text(verdict)],
            [.text(verdict)],
            [.text("两台的 502 是同一个原因：21:02 应用进程因内存不足被杀。建议把 JVM 的 -Xmx 调到 4g，或给机器加交换空间。")],
        ])
        var doctor = ParallelAIDoctor(client: llm, model: "claude-sonnet-5-5",
                                      baseURL: URL(string: "https://example.invalid")!, apiKey: "catalog")
        doctor.retryDelay = { _ in .zero }
        return doctor
    }
}

// MARK: - 并行执行的假执行器

/// 按主机名回写好的输出；不连任何机器。
struct UICatalogParallelExecutor: ParallelCommandExecuting {
    func makeSession(for profile: ServerProfile, approving pin: HostKeyApprovalPin?) async -> ParallelExecutionSession {
        UICatalogParallelSession(host: profile.name)
    }
}

nonisolated final class UICatalogParallelSession: ParallelExecutionSession, @unchecked Sendable {
    let host: String
    init(host: String) { self.host = host }

    var setupErrorText: String? { nil }

    func run(_ command: String,
             onLines: @escaping @Sendable ([ParallelTermLine]) -> Void) async throws -> CommandResult {
        try await Task.sleep(for: .milliseconds(80))
        if command.hasPrefix("df") {
            let rows: [String: String] = [
                "prod-web-01": "/dev/vda1        80G   41G   36G  54% /",
                "prod-web-02": "/dev/vda1        80G   44G   33G  58% /",
                "prod-db": "/dev/nvme0n1p2  500G  410G   65G  87% /",
                "staging": "/dev/sda1        40G  9.1G   29G  24% /",
                "k3s-lab": "/dev/sda2       120G   61G   53G  54% /",
                "nas": "/dev/md0        7.3T  5.1T  2.2T  70% /",
            ]
            return CommandResult(output: rows[host] ?? "/dev/sda1  40G  10G  28G  27% /", exitCode: 0)
        }
        if command.contains("error.log") {
            return CommandResult(output: """
            2026/11/20 21:02:13 [error] 1124#1124: *88214 connect() failed (111: Connection refused) while connecting to upstream
            2026/11/20 21:02:14 [error] 1124#1124: *88219 no live upstreams while connecting to upstream
            """, exitCode: 0)
        }
        if command.contains("journalctl") || command.contains("dmesg") {
            return CommandResult(output: "Out of memory: Killed process 41823 (java) total-vm:6391204kB", exitCode: 0)
        }
        return CommandResult(output: "ok", exitCode: 0)
    }

    func takeHostKeyChallenge() -> HostKeyChallenge? { nil }
    func close() async {}
}
