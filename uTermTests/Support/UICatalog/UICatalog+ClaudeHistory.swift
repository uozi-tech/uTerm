import Foundation
@testable import uTerm

/// 「Claude 历史会话」窗口的假数据：一台主机上的 `~/.claude/projects`，全是手写的（`ClaudeFixture`）。
@MainActor
enum UICatalogClaudeHistory {
    static let directory = "/home/deploy/shop-api"
    private static let root = "/home/user/.claude/projects"
    private static let project = ClaudeProjectPath.encode(directory)

    static func model() async -> AgentHistoryModel {
        let now = UICatalogFixtures.now
        let sessions: [(id: String, data: Data, age: TimeInterval)] = [
            ("6f1d2c3b-4a5e-4f60-8172-93a4b5c6d7e8", conversation(), 60 * 12),
            ("1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d", simple(title: "给订单接口加分页", ask: "订单列表接口加上分页参数"), 3600 * 5),
            ("9e8d7c6b-5a4f-4e3d-8c2b-1a0f9e8d7c6b", simple(title: "排查 502", ask: "nginx 偶尔回 502，帮我看看"), 86_400 * 2),
            ("0f0e0d0c-0b0a-4908-8706-050403020100", desktop(), 86_400 * 3),
        ]
        var tree: [String: [RemoteEntry]] = [root: [ClaudeFixture.entry(project, directory: true, mtime: now)]]
        tree["\(root)/\(project)"] = sessions.map {
            ClaudeFixture.entry("\($0.id).jsonl", size: UInt64($0.data.count), mtime: now.addingTimeInterval(-$0.age))
        }
        let sftp = MockSFTP(tree: tree)
        for session in sessions {
            await sftp.setFile("\(root)/\(project)/\(session.id).jsonl", data: session.data,
                               mtime: now.addingTimeInterval(-session.age))
        }
        let history = AgentHistoryModel(source: ClaudeHistorySource(provider: sftp), preferredDirectory: directory)
        await history.start()
        for file in history.files { history.rowAppeared(file) }
        for _ in 0..<100 where history.metadata.count < history.files.count {
            try? await Task.sleep(for: .milliseconds(10))
        }
        if let first = history.visibleFiles.first { history.select(first) }
        for _ in 0..<100 where history.transcript?.reachedStart != true {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return history
    }

    private static func conversation() -> Data {
        let cwd = directory
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
