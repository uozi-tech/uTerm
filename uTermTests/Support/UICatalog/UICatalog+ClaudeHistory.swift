import Foundation
@testable import uTerm

/// 「Claude 历史会话」窗口的假数据：一台主机上的 `~/.claude/projects`，全是手写的（`ClaudeFixture`）。
@MainActor
enum UICatalogClaudeHistory {
    static let directory = "/home/deploy/shop-api"
    private static let root = "/home/user/.claude/projects"
    private static let project = ClaudeProjectPath.encode(directory)

    /// 打开哪一份：默认是最新的那段对话；`subagents` 是派了子代理的那份，`subagentTranscript` 再点进其中一个子代理；
    /// `live` 是最新那段对话还开着：往上翻着时末尾又写进了一问一答（标题旁「正在更新」、底部「有新消息」）。
    /// `search` 是列表顶上搜了「订单」（结果按会话分组）；`searchHit` 再点开其中一条命中（停在那一条上、整条高亮）。
    enum Opening {
        case conversation, subagents, subagentTranscript, live, search, searchHit
    }

    /// `live` 那一份记录在哪（`appendLiveTurn` 往它末尾写）。
    private static var liveFile: (sftp: MockSFTP, path: String)?

    /// 还开着的会话又写进了一问一答，跟随看一次文件末尾。
    static func appendLiveTurn(_ history: AgentHistoryModel) async {
        guard let liveFile, let transcript = history.transcript else { return }
        var data = (try? await liveFile.sftp.readRange(liveFile.path, offset: 0, length: Int.max / 2)) ?? Data()
        // 新接上的这一问一答是刚写的：时间戳取此刻，顶栏的「最后活动」才和「正在更新」对得上。
        let stamp = Date().formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        let turn = ClaudeFixture.userText("顺便把慢查询日志也打开吧。", uuid: "u-live", cwd: directory) + "\n"
            + ClaudeFixture.assistant(ClaudeFixture.textBlock("好，已经在 `postgresql.conf` 里打开了。"),
                                      uuid: "a-live", cwd: directory) + "\n"
        data.append(Data(turn.replacingOccurrences(of: "2026-11-20T10:00:00.000Z", with: stamp).utf8))
        await liveFile.sftp.setFile(liveFile.path, data: data, mtime: UICatalogFixtures.now)
        await transcript.followOnce()
    }

    static let agentsSessionID = "3c4d5e6f-7a8b-4c9d-8e0f-1a2b3c4d5e6f"

    static func model(opening: Opening = .conversation) async -> AgentHistoryModel {
        let now = UICatalogFixtures.now
        let sessions: [(id: String, data: Data, age: TimeInterval)] = [
            ("6f1d2c3b-4a5e-4f60-8172-93a4b5c6d7e8", conversation(followUps: opening == .live ? 6 : 0), 60 * 12),
            (agentsSessionID, withSubagents(), 60 * 40),
            ("1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d", simple(title: "给订单接口加分页", ask: "订单列表接口加上分页参数"), 3600 * 5),
            ("9e8d7c6b-5a4f-4e3d-8c2b-1a0f9e8d7c6b", simple(title: "排查 502", ask: "nginx 偶尔回 502，帮我看看"), 86_400 * 2),
            ("0f0e0d0c-0b0a-4908-8706-050403020100", desktop(), 86_400 * 3),
        ]
        var tree: [String: [RemoteEntry]] = [root: [ClaudeFixture.entry(project, directory: true, mtime: now)]]
        tree["\(root)/\(project)"] = sessions.map {
            ClaudeFixture.entry("\($0.id).jsonl", size: UInt64($0.data.count), mtime: now.addingTimeInterval(-$0.age))
        }
        let subagentsDir = "\(root)/\(project)/\(agentsSessionID)/subagents"
        let agentTime = now.addingTimeInterval(-60 * 38)
        tree["\(root)/\(project)"]?.append(ClaudeFixture.entry(agentsSessionID, directory: true, mtime: now))
        tree["\(root)/\(project)/\(agentsSessionID)"] = [ClaudeFixture.entry("subagents", directory: true, mtime: now)]
        let agents = subagents()
        tree[subagentsDir] = agents.flatMap { agent -> [RemoteEntry] in
            [ClaudeFixture.entry("agent-\(agent.id).jsonl", size: UInt64(agent.data.count), mtime: agentTime),
             ClaudeFixture.entry("agent-\(agent.id).meta.json", size: UInt64(agent.meta.count), mtime: agentTime)]
        }
        let sftp = MockSFTP(tree: tree)
        for session in sessions {
            await sftp.setFile("\(root)/\(project)/\(session.id).jsonl", data: session.data,
                               mtime: now.addingTimeInterval(-session.age))
        }
        for agent in agents {
            await sftp.setFile("\(subagentsDir)/agent-\(agent.id).jsonl", data: agent.data, mtime: agentTime)
            await sftp.setFile("\(subagentsDir)/agent-\(agent.id).meta.json", data: agent.meta, mtime: agentTime)
        }
        await sftp.answersClaudeSearch()
        let history = AgentHistoryModel(source: ClaudeHistorySource(provider: sftp), preferredDirectory: directory)
        await history.start()
        for _ in 0..<100 where history.hasMore {
            try? await Task.sleep(for: .milliseconds(10))
        }
        if opening == .search || opening == .searchHit {
            history.searchText = "订单"
            history.submitSearch()
            for _ in 0..<200 where history.search?.phase != .finished {
                try? await Task.sleep(for: .milliseconds(10))
            }
            guard opening == .searchHit, let session = history.search?.sessions.first,
                  let hit = session.hits.dropFirst().first ?? session.hits.first else { return history }
            history.openHit(hit, in: session)
            for _ in 0..<100 where history.transcript?.items.isEmpty != false {
                try? await Task.sleep(for: .milliseconds(10))
            }
            return history
        }
        let pick = opening == .conversation || opening == .live ? history.visibleFiles.first
            : history.visibleFiles.first { $0.sessionID == agentsSessionID }
        if let pick { history.select(pick) }
        for _ in 0..<100 where history.transcript?.reachedStart != true {
            try? await Task.sleep(for: .milliseconds(10))
        }
        if opening == .live {
            // 新内容等画面挂上、往上翻过之后再写（`appendLiveTurn`）。
            liveFile = history.selectedFile.map { (sftp, $0.path) }
            return history
        }
        guard opening != .conversation, let transcript = history.transcript else { return history }
        for _ in 0..<100 where transcript.subagentLinks.count < 2 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard opening == .subagentTranscript, let link = transcript.subagentLinks["toolu_s2"] else { return history }
        history.openSubagent(link)
        for _ in 0..<100 where history.displayedTranscript?.reachedStart != true
            || history.displayedTranscript?.subagentLinks.isEmpty != false {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return history
    }

    /// 派了两个子代理的会话。
    private static func withSubagents() -> Data {
        let cwd = directory
        return ClaudeFixture.file([
            ClaudeFixture.userText("给订单服务补上集成测试，顺便看看订单列表为什么慢。", cwd: cwd),
            ClaudeFixture.assistant(ClaudeFixture.textBlock("分两路并行：一路写测试，一路查慢查询。"), cwd: cwd),
            ClaudeFixture.assistant(ClaudeFixture.spawn(id: "toolu_s1", description: "补订单服务的集成测试"), uuid: "a-2", cwd: cwd),
            ClaudeFixture.assistant(ClaudeFixture.spawn(id: "toolu_s2", description: "排查订单列表的慢查询", type: "Explore"),
                                    uuid: "a-3", cwd: cwd),
            ClaudeFixture.spawnResult(id: "toolu_s1", agentID: "a7c1e9", text: "补了 6 个用例，全部通过。"),
            ClaudeFixture.spawnResult(id: "toolu_s2", agentID: "b3d8f2", text: "慢在 orders.created_at 没有索引，加上后 1.8s → 40ms。"),
            ClaudeFixture.assistant(ClaudeFixture.textBlock("""
                两边都好了：

                - 集成测试补了 6 个用例，全部通过；
                - 订单列表慢是因为 `orders.created_at` 没有索引，迁移脚本已经加上。
                """), uuid: "a-4", cwd: cwd),
            ClaudeFixture.aiTitle("订单服务测试与慢查询"),
        ])
    }

    /// 两个子代理的记录；查慢查询的那个又派了一个子代理（第二层）。
    private static func subagents() -> [(id: String, data: Data, meta: Data)] {
        [
            ("a7c1e9", ClaudeFixture.file([
                ClaudeFixture.sidechainUser("为订单服务补集成测试：下单、取消、退款各两条。", agentID: "a7c1e9"),
                ClaudeFixture.sidechainAssistant(ClaudeFixture.toolUse(id: "toolu_t1", name: "Bash",
                                                                       input: #"{"command":"go test ./internal/order/..."}"#),
                                                 agentID: "a7c1e9"),
                ClaudeFixture.sidechainAssistant(ClaudeFixture.textBlock("补了 6 个用例，全部通过。"), agentID: "a7c1e9", uuid: "s-a-2"),
            ]), ClaudeFixture.subagentMeta(toolUseID: "toolu_s1", description: "补订单服务的集成测试")),
            ("b3d8f2", ClaudeFixture.file([
                ClaudeFixture.sidechainUser("订单列表接口偶尔要 2 秒，找出慢在哪。", agentID: "b3d8f2"),
                ClaudeFixture.sidechainAssistant(ClaudeFixture.thinkingBlock("先看慢查询日志，再看执行计划。"), agentID: "b3d8f2"),
                ClaudeFixture.sidechainAssistant(ClaudeFixture.toolUse(id: "toolu_g1", name: "Grep",
                                                                       input: #"{"pattern":"ORDER BY created_at"}"#),
                                                 agentID: "b3d8f2", uuid: "s-a-2"),
                ClaudeFixture.sidechainAssistant(ClaudeFixture.spawn(id: "toolu_s3", description: "核对索引前后的执行计划", type: "Explore"),
                                                 agentID: "b3d8f2", uuid: "s-a-3"),
                ClaudeFixture.sidechainAssistant(ClaudeFixture.textBlock("慢在 `orders.created_at` 没有索引，加上后 1.8s → 40ms。"),
                                                 agentID: "b3d8f2", uuid: "s-a-4"),
            ]), ClaudeFixture.subagentMeta(toolUseID: "toolu_s2", type: "Explore", description: "排查订单列表的慢查询")),
            ("c9e4a0", ClaudeFixture.file([
                ClaudeFixture.sidechainUser("对比加索引前后的 EXPLAIN。", agentID: "c9e4a0"),
                ClaudeFixture.sidechainAssistant(ClaudeFixture.textBlock("加索引后走 index scan，扫描行数从 120 万降到 50。"),
                                                 agentID: "c9e4a0"),
            ]), ClaudeFixture.subagentMeta(toolUseID: "toolu_s3", type: "Explore", description: "核对索引前后的执行计划", depth: 2)),
        ]
    }

    /// `followUps`：后面再追问几轮（「实时跟随」那张要比一屏长，才翻得上去）。
    private static func conversation(followUps: Int = 0) -> Data {
        let cwd = directory
        var extra: [String] = []
        for turn in 0..<followUps {
            extra.append(ClaudeFixture.userText("压测第 \(turn + 1) 轮还有超时吗？", uuid: "u-f\(turn)", cwd: cwd))
            extra.append(ClaudeFixture.assistant(ClaudeFixture.textBlock("第 \(turn + 1) 轮没有超时，p99 在 120ms 以内。"),
                                                 uuid: "a-f\(turn)", cwd: cwd))
        }
        return ClaudeFixture.file([
            ClaudeFixture.noise(0),
            ClaudeFixture.userText("登录接口偶尔返回 500，日志里是 `context deadline exceeded`。帮我找找原因。", cwd: cwd),
            ClaudeFixture.assistant(ClaudeFixture.thinkingBlock("先看 handler 里数据库调用的超时设置，再看连接池。"), cwd: cwd),
            ClaudeFixture.assistant(ClaudeFixture.textBlock("先看一下登录的处理函数。"), cwd: cwd),
            ClaudeFixture.assistant(ClaudeFixture.toolUse(id: "toolu_01", name: "Grep",
                                                          input: #"{"pattern":"func Login","path":"internal"}"#), cwd: cwd),
            ClaudeFixture.toolResult(id: "toolu_01", text: "internal/auth/handler.go:42:func Login(w http.ResponseWriter, r *http.Request) {"),
            ClaudeFixture.assistant(ClaudeFixture.toolUse(id: "toolu_02", name: "Bash",
                                                          input: #"{"command":"go test ./internal/auth/... -run TestLogin"}"#), cwd: cwd),
            ClaudeFixture.toolResult(id: "toolu_02", text: "--- FAIL: TestLoginTimeout (2.01s)\n    handler_test.go:88: context deadline exceeded\nFAIL"),
            ClaudeFixture.assistant(ClaudeFixture.textBlock("""
                原因找到了：`Login` 每次请求都新建数据库连接，连接池上限只有 **5**，高峰时排队超过 2 秒的超时。

                建议：

                1. 复用 `db.Pool`，不要在 handler 里 `Open`；
                2. 把 `MaxOpenConns` 调到 20。

                ```go
                pool.SetMaxOpenConns(20)
                ```
                """), cwd: cwd),
            ClaudeFixture.user(content: ClaudeFixture.json("此前的对话：定位到登录超时是连接池太小。"), cwd: cwd,
                               flags: #","isCompactSummary":true"#),
            ClaudeFixture.userText("<command-name>/review</command-name>\n<command-message>review</command-message>\n<command-args></command-args>", cwd: cwd),
            ClaudeFixture.userText("按第一条改吧，顺便补个测试。", cwd: cwd),
            ClaudeFixture.assistant(ClaudeFixture.textBlock("改好了，`TestLoginTimeout` 现在能过。"), cwd: cwd),
        ] + extra + [
            ClaudeFixture.aiTitle("登录接口偶发 500"),
        ])
    }

    private static func simple(title: String, ask: String) -> Data {
        ClaudeFixture.file([ClaudeFixture.userText(ask, cwd: directory),
                            ClaudeFixture.assistant(ClaudeFixture.textBlock("好的。"), cwd: directory),
                            ClaudeFixture.aiTitle(title)])
    }

    private static func desktop() -> Data {
        ClaudeFixture.file([ClaudeFixture.userText("桌面版的会话", entrypoint: "claude-desktop", cwd: directory),
                            ClaudeFixture.customTitle("桌面版")])
    }
}
