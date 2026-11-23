import Foundation
@testable import uTermMobile

/// 「Claude 历史会话」标签的假数据：一台主机上的 `~/.claude/projects`，全是手写的（结构照 Claude Code 2.1.x 的记录行，
/// 内容全是编的）。仓库是公开的：这里绝不能放真实的对话、路径、账号。
enum MobileClaudeFixture {
    static let home = "/home/user"
    static let directory = "/home/user/projects/shop-api"
    static var projectsRoot: String { home + "/.claude/projects" }
    static var project: String { ClaudeProjectPath.encode(directory) }
    static var projectPath: String { projectsRoot + "/" + project }

    static func json(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        return String(data: data, encoding: .utf8)!
    }

    static func meta(_ entrypoint: String, cwd: String) -> String {
        #""timestamp":"2026-11-20T10:00:00.000Z","cwd":"\#(cwd)","sessionId":"x","version":"2.1.330","gitBranch":"main","entrypoint":"\#(entrypoint)""#
    }

    static func user(_ text: String, uuid: String = "u-1", entrypoint: String = "cli", cwd: String = directory) -> String {
        #"{"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":\#(json(text))},"uuid":"\#(uuid)",\#(meta(entrypoint, cwd: cwd))}"#
    }

    static func assistant(_ blocks: String, uuid: String = "a-1", cwd: String = directory) -> String {
        #"{"parentUuid":"u-1","isSidechain":false,"message":{"model":"test-model","id":"msg_1","type":"message","role":"assistant","content":[\#(blocks)]},"type":"assistant","uuid":"\#(uuid)",\#(meta("cli", cwd: cwd))}"#
    }

    static func text(_ text: String) -> String { #"{"type":"text","text":\#(json(text))}"# }
    static func thinking(_ text: String) -> String { #"{"type":"thinking","thinking":\#(json(text)),"signature":"sig"}"# }
    static func toolUse(id: String, name: String, input: String) -> String {
        #"{"type":"tool_use","id":"\#(id)","name":"\#(name)","input":\#(input)}"#
    }
    static func toolResult(id: String, text: String) -> String {
        #"{"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":[{"tool_use_id":"\#(id)","type":"tool_result","content":\#(json(text)),"is_error":false}]},"uuid":"r-\#(id)",\#(meta("cli", cwd: directory))}"#
    }
    static func title(_ title: String) -> String { #"{"type":"ai-title","aiTitle":\#(json(title)),"sessionId":"x"}"# }

    static func file(_ lines: [String]) -> Data { Data((lines.joined(separator: "\n") + "\n").utf8) }

    static func sessionID(_ index: Int) -> String { String(format: "%08x-1111-4222-8333-%012x", index, index) }

    /// 一段像样的对话（截图用）。
    static func conversation() -> Data {
        file([
            user("登录接口偶尔返回 500，日志里是 `context deadline exceeded`。帮我找找原因。"),
            assistant(thinking("先看 handler 里数据库调用的超时设置，再看连接池。")),
            assistant(text("先看一下登录的处理函数。")),
            assistant(toolUse(id: "toolu_01", name: "Grep", input: #"{"pattern":"func Login","path":"internal"}"#)),
            toolResult(id: "toolu_01", text: "internal/auth/handler.go:42:func Login(w http.ResponseWriter, r *http.Request) {"),
            assistant(text("""
                原因找到了：`Login` 每次请求都新建数据库连接，连接池上限只有 **5**，高峰时排队超过 2 秒就超时。

                建议复用 `db.Pool`，并把 `MaxOpenConns` 调到 20。
                """)),
            user("按这个改吧，顺便补个测试。"),
            assistant(text("改好了，`TestLoginTimeout` 现在能过。")),
            title("登录接口偶发 500"),
        ])
    }

    static func simple(title name: String, ask: String) -> Data {
        file([user(ask), assistant(text("好的。")), title(name)])
    }

    static func desktop() -> Data {
        file([user("桌面版的会话", entrypoint: "claude-desktop"), title("桌面版")])
    }

    /// 比一屏长得多的对话：打开时该停在最后一条。
    static func long(turns: Int = 30) -> Data {
        var lines: [String] = []
        for turn in 1...turns {
            lines.append(user("第 \(turn) 个问题：这一步该怎么做？", uuid: "u-\(turn)"))
            lines.append(assistant(text("第 \(turn) 个回答：先看日志，再看配置，最后重启服务确认。"), uuid: "a-\(turn)"))
        }
        lines.append(title("一段很长的对话"))
        return file(lines)
    }

    /// 只有一条很长的会话。
    static func longOnly(now: Date = Date()) -> MobileFakeClaudeTree {
        MobileFakeClaudeTree(home: home, files: [
            (projectPath + "/" + sessionID(9) + ".jsonl", long(), now.addingTimeInterval(-60)),
        ])
    }

    // MARK: 子代理

    static func spawn(id: String, description: String, type: String = "general-purpose") -> String {
        toolUse(id: id, name: "Agent",
                input: #"{"description":\#(json(description)),"prompt":"按说明去做","subagent_type":\#(json(type))}"#)
    }

    /// 派子代理那次调用的结果，行顶层带 `toolUseResult.agentId`。
    static func spawnResult(id: String, agentID: String, text: String) -> String {
        #"{"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":[{"tool_use_id":"\#(id)","type":"tool_result","content":[{"type":"text","text":\#(json(text))}]}]},"uuid":"r-\#(id)",\#(meta("cli", cwd: directory)),"toolUseResult":{"status":"completed","agentId":"\#(agentID)"}}"#
    }

    static func sideUser(_ text: String, agent: String) -> String {
        #"{"parentUuid":null,"isSidechain":true,"agentId":"\#(agent)","type":"user","message":{"role":"user","content":\#(json(text))},"uuid":"s-u",\#(meta("cli", cwd: directory))}"#
    }

    static func sideAssistant(_ blocks: String, agent: String, uuid: String = "s-a") -> String {
        #"{"parentUuid":"s-u","isSidechain":true,"agentId":"\#(agent)","message":{"model":"test-model","id":"msg_s","type":"message","role":"assistant","content":[\#(blocks)]},"type":"assistant","uuid":"\#(uuid)",\#(meta("cli", cwd: directory))}"#
    }

    static func subagentMeta(toolUseID: String, type: String, description: String) -> Data {
        Data(#"{"agentType":\#(json(type)),"description":\#(json(description)),"spawnDepth":1,"toolUseId":"\#(toolUseID)"}"#.utf8)
    }

    /// 派了两个子代理的会话（第二个又派了一个）。主对话之外，`<会话>/subagents/` 下有三份记录和它们的 meta。
    static func withSubagents(now: Date = Date()) -> MobileFakeClaudeTree {
        let session = sessionID(7)
        let dir = projectPath + "/" + session + "/subagents"
        let main = file([
            user("给订单服务补上集成测试，顺便看看订单列表为什么慢。"),
            assistant(text("分两路并行：一路写测试，一路查慢查询。")),
            assistant(spawn(id: "toolu_s1", description: "补订单服务的集成测试"), uuid: "a-2"),
            assistant(spawn(id: "toolu_s2", description: "排查订单列表的慢查询", type: "Explore"), uuid: "a-3"),
            spawnResult(id: "toolu_s1", agentID: "a7c1e9", text: "补了 6 个用例，全部通过。"),
            spawnResult(id: "toolu_s2", agentID: "b3d8f2", text: "慢在 orders.created_at 没有索引。"),
            assistant(text("两边都好了：测试补了 6 个用例；订单列表慢是因为 `orders.created_at` 没有索引，迁移脚本已经加上。"),
                      uuid: "a-4"),
            title("订单服务测试与慢查询"),
        ])
        let first = file([
            sideUser("为订单服务补集成测试：下单、取消、退款各两条。", agent: "a7c1e9"),
            sideAssistant(toolUse(id: "toolu_t1", name: "Bash", input: #"{"command":"go test ./internal/order/..."}"#),
                          agent: "a7c1e9"),
            sideAssistant(text("补了 6 个用例，全部通过。"), agent: "a7c1e9", uuid: "s-a-2"),
        ])
        let second = file([
            sideUser("订单列表接口偶尔要 2 秒，找出慢在哪。", agent: "b3d8f2"),
            sideAssistant(thinking("先看慢查询日志，再看执行计划。"), agent: "b3d8f2"),
            sideAssistant(spawn(id: "toolu_s3", description: "核对索引前后的执行计划", type: "Explore"), agent: "b3d8f2",
                          uuid: "s-a-2"),
            sideAssistant(text("慢在 `orders.created_at` 没有索引，加上后 1.8s → 40ms。"), agent: "b3d8f2", uuid: "s-a-3"),
        ])
        let third = file([
            sideUser("对比加索引前后的 EXPLAIN。", agent: "c9e4a0"),
            sideAssistant(text("加索引后走 index scan，扫描行数从 120 万降到 50。"), agent: "c9e4a0"),
        ])
        let time = now.addingTimeInterval(-60 * 30)
        return MobileFakeClaudeTree(home: home, files: [
            (projectPath + "/" + session + ".jsonl", main, now.addingTimeInterval(-60 * 20)),
            (dir + "/agent-a7c1e9.jsonl", first, time),
            (dir + "/agent-a7c1e9.meta.json", subagentMeta(toolUseID: "toolu_s1", type: "general-purpose",
                                                           description: "补订单服务的集成测试"), time),
            (dir + "/agent-b3d8f2.jsonl", second, time),
            (dir + "/agent-b3d8f2.meta.json", subagentMeta(toolUseID: "toolu_s2", type: "Explore",
                                                           description: "排查订单列表的慢查询"), time),
            (dir + "/agent-c9e4a0.jsonl", third, time),
            (dir + "/agent-c9e4a0.meta.json", subagentMeta(toolUseID: "toolu_s3", type: "Explore",
                                                           description: "核对索引前后的执行计划"), time),
        ])
    }

    /// 截图与用例共用的一份：三条命令行会话 + 一条桌面版（不列出）。
    static func standard(now: Date = Date()) -> MobileFakeClaudeTree {
        MobileFakeClaudeTree(home: home, files: [
            (projectPath + "/" + sessionID(1) + ".jsonl", conversation(), now.addingTimeInterval(-60 * 12)),
            (projectPath + "/" + sessionID(2) + ".jsonl", simple(title: "给订单接口加分页", ask: "订单列表接口加上分页参数"),
             now.addingTimeInterval(-3600 * 5)),
            (projectPath + "/" + sessionID(3) + ".jsonl", simple(title: "排查 502", ask: "nginx 偶尔回 502，帮我看看"),
             now.addingTimeInterval(-86_400 * 2)),
            (projectPath + "/" + sessionID(4) + ".jsonl", desktop(), now.addingTimeInterval(-86_400 * 3)),
        ])
    }
}

/// 只读的内存文件树：只认历史会话要用的几样（列目录、属性、按区间读、解析主目录），其余一律报错——
/// 历史会话不能往主机上写任何东西，写了这里就会抛。
actor MobileFakeClaudeTree: SFTPProviding {
    nonisolated struct Unsupported: Error {}

    private let home: String
    private var files: [String: (data: Data, mtime: Date)] = [:]
    private var directories: [String: Date] = [:]
    private(set) var didClose = false

    init(home: String, files: [(path: String, data: Data, mtime: Date)]) {
        self.home = home
        for file in files {
            self.files[file.path] = (file.data, file.mtime)
            var parent = (file.path as NSString).deletingLastPathComponent
            while parent.count > 1 {
                directories[parent] = max(directories[parent] ?? .distantPast, file.mtime)
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
    }

    func list(path: String) async throws -> [RemoteEntry] {
        guard directories[path] != nil else { throw Unsupported() }
        let prefix = path + "/"
        var names: [String: RemoteEntry] = [:]
        for (dir, mtime) in directories where dir.hasPrefix(prefix) && !dir.dropFirst(prefix.count).contains("/") {
            let name = String(dir.dropFirst(prefix.count))
            names[name] = RemoteEntry(name: name, posixPermissions: 0o040755, size: nil, modifiedAt: mtime)
        }
        for (file, value) in files where file.hasPrefix(prefix) && !file.dropFirst(prefix.count).contains("/") {
            let name = String(file.dropFirst(prefix.count))
            names[name] = RemoteEntry(name: name, posixPermissions: 0o100644, size: UInt64(value.data.count),
                                      modifiedAt: value.mtime)
        }
        return Array(names.values)
    }

    func realPath(_ path: String) async throws -> String { path == "." ? home : path }

    /// 往一份记录末尾追加（模拟还开着的会话在写）。只给用例造数据用，历史会话自己从不写。
    func append(_ path: String, _ text: String, mtime: Date = Date()) {
        guard var file = files[path] else { return }
        file.data.append(Data(text.utf8))
        file.mtime = mtime
        files[path] = file
    }

    func stat(_ path: String) async throws -> RemoteStat {
        if let file = files[path] { return RemoteStat(size: Int64(file.data.count), mtime: file.mtime, permissions: 0o100644) }
        if let mtime = directories[path] { return RemoteStat(size: 4096, mtime: mtime, permissions: 0o040755) }
        throw Unsupported()
    }

    func download(remotePath: String) async throws -> Data {
        guard let file = files[remotePath] else { throw Unsupported() }
        return file.data
    }

    func readRange(_ path: String, offset: UInt64, length: Int) async throws -> Data {
        guard let data = files[path]?.data else { throw Unsupported() }
        let start = min(Int(offset), data.count), end = min(start + length, data.count)
        return data.subdata(in: start..<end)
    }

    func download(remotePath: String, onProgress: (@Sendable (TransferProgress) -> Void)?) async throws -> Data {
        try await download(remotePath: remotePath)
    }

    func close() async { didClose = true }

    // 历史会话只读：下面这些一律不支持。
    func upload(data: Data, toRemotePath: String) async throws { throw Unsupported() }
    func write(_ path: String, data: Data) async throws { throw Unsupported() }
    func exec(_ command: String) async throws -> String { throw Unsupported() }
    func rename(_ path: String, to newPath: String) async throws { throw Unsupported() }
    func removeFile(_ path: String) async throws { throw Unsupported() }
    func removeDirectory(_ path: String) async throws { throw Unsupported() }
    func createDirectory(_ path: String) async throws { throw Unsupported() }
    func createFile(_ path: String) async throws { throw Unsupported() }
    func setPermissions(path: String, mode: UInt32) async throws { throw Unsupported() }
    func upload(data: Data, toRemotePath: String, onProgress: (@Sendable (TransferProgress) -> Void)?) async throws {
        throw Unsupported()
    }
    func download(remotePath: String, toLocalURL localURL: URL,
                  onProgress: (@Sendable (TransferProgress) -> Void)?) async throws { throw Unsupported() }
    func upload(localURL: URL, toRemotePath: String,
                onProgress: (@Sendable (TransferProgress) -> Void)?) async throws { throw Unsupported() }
}

@MainActor
enum MobileFakeClaudeHistory {
    /// 一个接着假文件树的历史标签（还没开始读）。
    static func tab(host: ServerProfile, tree: MobileFakeClaudeTree, directory: String? = MobileClaudeFixture.directory)
        -> ClaudeHistoryTab {
        ClaudeHistoryTab(host: host, connection: AgentHistoryConnection(preferredDirectory: directory) { _ in tree })
    }

    /// 等列表读完（或超时）。
    @discardableResult
    static func settle(_ tab: ClaudeHistoryTab, timeout: Duration = .seconds(5)) async -> Bool {
        await MobileFakeTerminal.waitUntil(timeout: timeout) {
            guard let history = tab.connection.history else { return false }
            return history.phase != .loading && !history.isListing && !history.hasMore
        }
    }
}
