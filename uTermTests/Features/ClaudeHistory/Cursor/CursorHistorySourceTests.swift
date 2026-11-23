import Foundation
import XCTest
@testable import uTerm

/// Cursor 命令行的数据源：列表、项目（工作目录哈希）、元数据、对话解析、分页、跟随、命令。库全是测试里现建的假数据。
final class CursorHistorySourceTests: XCTestCase {
    private typealias F = CursorFixture

    private func basicChat(name: String = "修复登录页") throws -> CursorFixture.Chat {
        let chat = try CursorFixture.Chat(name: name)
        chat.turns = [.agent(user: "帮我看看登录为什么失败", steps: [
            F.thinking("先读一下代码"),
            F.read("/home/user/projects/demo/src/login.ts", content: "export function login() {}"),
            F.assistant("问题在 token 过期判断。"),
        ])]
        try chat.save()
        return chat
    }

    private func host(with chats: [(path: String, chat: CursorFixture.Chat)], mtime: Date = F.createdAt) async throws -> SQLiteTestHost {
        let host = SQLiteTestHost(home: F.home)
        for (path, chat) in chats { await host.install(try chat.snapshot(), at: path, mtime: mtime) }
        return host
    }

    // MARK: - 项目与列表

    func testHashMatchesIndependentMD5() {
        XCTAssertEqual(CursorWorkspace.hash(of: F.workspace), F.workspaceHash)
        XCTAssertEqual(CursorWorkspace.hash(of: F.otherWorkspace), F.otherHash)
        XCTAssertTrue(CursorWorkspace.isHashName(F.workspaceHash))
        XCTAssertFalse(CursorWorkspace.isHashName("E1E1F140B746C569BE2DAA533D62EE33"))
        XCTAssertFalse(CursorWorkspace.isHashName("not-a-hash"))
    }

    func testListsProjectsAndResolvesTheirWorkspaces() async throws {
        let demo = try basicChat()
        // 另一个项目：提示里写的目录对不上目录名（比如用 --workspace 换过目录），根上的 URI 才是对的。
        let api = try CursorFixture.Chat(name: "接口", workspaceURI: "file:///home/user/work/api",
                                         promptWorkspace: "/home/user/somewhere-else")
        api.turns = [.agent(user: "加个接口", steps: [F.assistant("好的")])]
        try api.save()
        // 第三个：什么都对不上，目录留空。
        let lost = try CursorFixture.Chat(name: "无主", promptWorkspace: "/tmp/elsewhere")
        lost.turns = [.agent(user: "随便问问", steps: [])]
        try lost.save()
        let lostHash = String(repeating: "ab", count: 16)

        let host = try await host(with: [
            (F.storePath(), demo),
            (F.storePath(hash: F.otherHash, session: F.otherSessionID), api),
            (F.storePath(hash: lostHash), lost),
        ])
        // 名字不像哈希的目录、隐藏文件不算项目。
        await host.put(F.chatsRoot + "/not-a-hash/x/store.db", Data())

        let source = CursorHistorySource(provider: host)
        XCTAssertEqual(source.tool, .cursor)
        XCTAssertFalse(source.supportsSearch)
        let projects = try await source.projects()
        XCTAssertEqual(Set(projects.map(\.id)), [F.workspaceHash, F.otherHash, lostHash])
        XCTAssertTrue(projects.allSatisfy { $0.tool == .cursor })
        let byID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        XCTAssertEqual(byID[F.workspaceHash]?.directory, F.workspace)
        XCTAssertEqual(byID[F.otherHash]?.directory, F.otherWorkspace)
        XCTAssertNil(byID[lostHash]?.directory)
        XCTAssertEqual(byID[F.workspaceHash]?.path, F.chatsRoot + "/" + F.workspaceHash)

        // 找过一次的不再找（库不再读）。
        await host.clearCounters()
        _ = try await source.projects()
        let reads = await host.reads
        XCTAssertTrue(reads.isEmpty, "工作目录已经核对过、项目也没变，又读了库")
        let writes = await host.writeAttempts
        XCTAssertEqual(writes, [])
    }

    func testNoRecordsMeansNoProjects() async throws {
        let host = SQLiteTestHost(home: F.home)
        await host.put("/home/user/.bashrc", Data("x".utf8))
        let projects = try await CursorHistorySource(provider: host).projects()
        XCTAssertEqual(projects, [])
    }

    func testAlsoLooksUnderXDGConfig() async throws {
        let chat = try basicChat()
        let root = F.home + "/.config/cursor/chats"
        let host = try await host(with: [(F.storePath(root: root), chat)])
        let projects = try await CursorHistorySource(provider: host).projects()
        XCTAssertEqual(projects.map(\.id), [F.workspaceHash])
        XCTAssertEqual(projects.first?.path, root + "/" + F.workspaceHash)
    }

    func testProjectContainingDirectoryUsesTheHash() async throws {
        let source = CursorHistorySource(provider: SQLiteTestHost(home: F.home))
        let projects = [AgentHistoryProject(id: F.workspaceHash, path: F.chatsRoot + "/" + F.workspaceHash, modifiedAt: nil,
                                            directory: nil, tool: .cursor),
                        AgentHistoryProject(id: F.otherHash, path: F.chatsRoot + "/" + F.otherHash, modifiedAt: nil,
                                            directory: nil, tool: .cursor)]
        let hit = await source.project(containing: F.workspace + "/src/components/", among: projects)
        XCTAssertEqual(hit?.id, F.workspaceHash)
        XCTAssertEqual(hit?.directory, F.workspace)
        let exact = await source.project(containing: F.otherWorkspace, among: projects)
        XCTAssertEqual(exact?.directory, F.otherWorkspace)
        let none = await source.project(containing: "/home/user/projects", among: projects)
        XCTAssertNil(none)
        let relative = await source.project(containing: "projects/demo", among: projects)
        XCTAssertNil(relative)
    }

    func testSessionsCountTheWALAndSkipStrayEntries() async throws {
        let older = try basicChat()
        let newer = try basicChat(name: "第二个")
        let host = try await host(with: [(F.storePath(), older)], mtime: F.createdAt)
        await host.install(try newer.snapshot(), at: F.storePath(session: F.otherSessionID),
                           mtime: F.createdAt.addingTimeInterval(600))
        // 会话目录里还没有库（刚建）、名字不是 UUID 的目录：都跳过。
        let base = F.chatsRoot + "/" + F.workspaceHash
        await host.put(base + "/11111111-2222-4333-8444-555555555555/notes.txt", Data("x".utf8))
        await host.put(base + "/junk/store.db", Data())

        let source = CursorHistorySource(provider: host)
        let project = try await source.projects().first { $0.id == F.workspaceHash }
        let files = try await source.sessions(in: try XCTUnwrap(project))
        XCTAssertEqual(files.map(\.sessionID), [F.otherSessionID, F.sessionID])
        let snapshot = try newer.snapshot()
        XCTAssertFalse(snapshot.wal.isEmpty)
        XCTAssertEqual(files.first?.size, UInt64(snapshot.main.count + snapshot.wal.count))
        XCTAssertEqual(files.first?.path, F.storePath(session: F.otherSessionID))
        XCTAssertEqual(files.first?.tool, .cursor)
        XCTAssertEqual(files.first?.project.directory, F.workspace)

        // WAL 比主文件新：修改时间取 WAL 的。
        let walTime = F.createdAt.addingTimeInterval(9_000)
        await host.put(F.storePath() + "-wal", try older.snapshot().wal, mtime: walTime)
        let again = try await source.sessions(in: try XCTUnwrap(project))
        XCTAssertEqual(again.first?.sessionID, F.sessionID)
        XCTAssertEqual(again.first?.modifiedAt, walTime)

        let all = await source.allSessions(in: try await source.projects())
        XCTAssertEqual(all.count, 2)
    }

    // MARK: - 元数据

    func testMetadataTitleDirectoryAndCache() async throws {
        let named = try basicChat(name: "修复登录页")
        let unnamed = try basicChat(name: CursorChatStore.defaultName)
        let host = try await host(with: [(F.storePath(), named), (F.storePath(session: F.otherSessionID), unnamed)])
        let source = CursorHistorySource(provider: host)
        let projects = try await source.projects()
        let project = try XCTUnwrap(projects.first)
        let files = try await source.sessions(in: project)
        let byID = Dictionary(uniqueKeysWithValues: files.map { ($0.sessionID, $0) })

        let info = try await source.metadata(for: try XCTUnwrap(byID[F.sessionID]))
        XCTAssertEqual(info.title, "修复登录页")
        XCTAssertTrue(info.isListed)
        XCTAssertEqual(info.resumeDirectory, F.workspace)
        XCTAssertEqual(info.lastDirectory, F.workspace)
        XCTAssertNil(info.gitBranch)
        XCTAssertNotNil(info.lastActivity)

        // 没起过名：用第一句话当标题。
        let fallback = try await source.metadata(for: try XCTUnwrap(byID[F.otherSessionID]))
        XCTAssertEqual(fallback.title, "帮我看看登录为什么失败")

        await host.clearCounters()
        _ = try await source.metadata(for: try XCTUnwrap(byID[F.sessionID]))
        let reads = await host.reads
        XCTAssertTrue(reads.isEmpty, "读过的元数据没走缓存")
    }

    func testEmptyChatIsNotListed() async throws {
        let empty = try CursorFixture.Chat()
        try empty.save(emptyRoot: true)
        let host = try await host(with: [(F.storePath(), empty)])
        let source = CursorHistorySource(provider: host)
        let projects = try await source.projects()
        let project = try XCTUnwrap(projects.first)
        let sessions = try await source.sessions(in: project)
        let file = try XCTUnwrap(sessions.first)
        let info = try await source.metadata(for: file)
        XCTAssertFalse(info.isListed)
        XCTAssertNil(info.title)
    }

    func testMetadataOfSomethingElseIsNotListed() async throws {
        // 会话目录里放的是一个不相干的 SQLite 库（没有 meta 表）。
        let db = try SQLiteFixtureDatabase()
        try SQLiteFixtureRows.create(db)
        try SQLiteFixtureRows.insert(db, 1..<3)
        let host = SQLiteTestHost(home: F.home)
        await host.install(try db.snapshot(), at: F.storePath())
        let source = CursorHistorySource(provider: host)
        let projects = try await source.projects()
        let project = try XCTUnwrap(projects.first)
        let sessions = try await source.sessions(in: project)
        let file = try XCTUnwrap(sessions.first)
        let info = try await source.metadata(for: file)
        XCTAssertFalse(info.isListed)
    }

    func testBrokenFileFailsMetadataWithAReadableError() async throws {
        let host = SQLiteTestHost(home: F.home)
        await host.put(F.storePath(), Data(repeating: 0x42, count: 4096))
        let source = CursorHistorySource(provider: host)
        let projects = try await source.projects()
        let project = try XCTUnwrap(projects.first)
        let sessions = try await source.sessions(in: project)
        let file = try XCTUnwrap(sessions.first)
        do {
            _ = try await source.metadata(for: file)
            XCTFail("坏文件也读出了元数据")
        } catch {
            XCTAssertEqual(error as? SQLiteRemoteReadError, .notSQLite)
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    // MARK: - 对话

    private func transcript(of chat: CursorFixture.Chat) throws -> [AgentTranscriptItem] {
        let snapshot = try chat.snapshot()
        return try CursorTranscriptParser.items(in: SQLiteMemoryDatabase(main: snapshot.main, wal: snapshot.wal))
    }

    func testParsesEveryKindOfStep() throws {
        let chat = try CursorFixture.Chat(name: "全都有")
        chat.turns = [
            .agent(user: "第一轮", steps: [
                F.thinking("想一想"),
                F.thinking(""),                                   // 只有用时的思考：不显示
                F.shell("ls -la", stdout: "total 0\n\u{1B}[32mok\u{1B}[0m"),
                F.shell("false", stdout: "出错了", exitCode: 1, failed: true),
                F.read("/home/user/projects/demo/a.txt", content: "第一行\n第二行"),
                F.readNotFound("/home/user/projects/demo/none.txt"),
                F.edit("/home/user/projects/demo/a.txt", diff: "-旧\n+新"),
                F.grep("TODO", file: "src/a.ts", line: 12, content: "// TODO: 修"),
                F.todos(["写测试", "跑测试"]),
                F.task("查目录结构", answer: "目录里有三个文件"),
                F.tool(99, args: ProtoWriter { $0.string(1, "未来的工具参数") }),
                F.assistant("都做完了。"),
            ]),
            .shell(command: "git status", stdout: "On branch main", stderr: ""),
            .agent(user: "第二轮", steps: [F.shell("make test")]),  // 还在跑：只有调用，没有结果
        ]
        try chat.save()
        let items = try transcript(of: chat)

        XCTAssertEqual(Set(items.map(\.id)).count, items.count, "条目 ID 重复")
        XCTAssertEqual(items.first?.id, "0.u")
        XCTAssertEqual(items.first?.kind, .userText("第一轮"))
        XCTAssertEqual(items.first?.timestamp, F.createdAt, "第一轮带会话的创建时间")
        XCTAssertEqual(items.first(where: { $0.id == "0.0" })?.kind, .thinking(AgentClippedText("想一想", limit: 100)))
        XCTAssertNil(items.first(where: { $0.id == "0.1" }), "空的思考不该显示")

        let assembled = AgentTranscriptAssembler.attachResults(items)
        let calls = assembled.compactMap { item -> AgentToolCall? in
            if case .toolCall(let call) = item.kind { return call }
            return nil
        }
        XCTAssertEqual(calls.map(\.name), ["Shell", "Shell", "Read", "Read", "Edit", "Grep", "TodoWrite", "Task", "Tool 99", "Shell"])
        XCTAssertEqual(calls[0].summary, "ls -la")
        XCTAssertEqual(calls[0].result?.content.text, "total 0\nok", "终端颜色去掉")
        XCTAssertEqual(calls[0].result?.isError, false)
        XCTAssertEqual(calls[1].result?.isError, true)
        XCTAssertEqual(calls[1].result?.content.text, "出错了")
        XCTAssertEqual(calls[2].summary, "/home/user/projects/demo/a.txt")
        XCTAssertEqual(calls[2].result?.content.text, "第一行\n第二行")
        XCTAssertEqual(calls[3].result?.isError, true)
        XCTAssertEqual(calls[3].result?.content.text, "文件不存在")
        XCTAssertEqual(calls[4].result?.content.text, "-旧\n+新", "编辑显示 diff，不显示整个文件")
        XCTAssertEqual(calls[5].summary, "TODO")
        XCTAssertEqual(calls[5].result?.content.text, "src/a.ts:12:// TODO: 修")
        XCTAssertEqual(calls[6].summary, "写测试; 跑测试")
        XCTAssertEqual(calls[7].summary, "查目录结构")
        XCTAssertEqual(calls[7].result?.content.text, "目录里有三个文件")
        XCTAssertNil(calls[7].spawn, "子代理的过程嵌在结果里，不去找单独的记录")
        XCTAssertEqual(calls[8].summary, "未来的工具参数")
        XCTAssertNil(calls[8].result)
        XCTAssertNil(calls[9].result, "还在跑的调用没有结果")
        XCTAssertFalse(assembled.contains { if case .toolResult = $0.kind { return true } else { return false } },
                       "每个结果都挂到了它的调用下面")

        XCTAssertTrue(items.contains { $0.id == "0.11" && $0.kind == .assistantText("都做完了。") })
        XCTAssertTrue(items.contains { $0.id == "1.c" && $0.kind == .command("! git status") })
        XCTAssertTrue(items.contains {
            $0.id == "1.o" && $0.kind == .commandOutput(AgentClippedText("On branch main", limit: 100))
        })
        XCTAssertEqual(items.last?.id, "2.0")
    }

    func testReadsTheLegacyTurnsField() throws {
        let chat = try CursorFixture.Chat(name: "旧版本")
        chat.legacy = true
        chat.turns = [.agent(user: "老格式", steps: [F.assistant("还能读")])]
        try chat.save()
        let items = try transcript(of: chat)
        XCTAssertEqual(items.map(\.kind), [.userText("老格式"), .assistantText("还能读")])
    }

    func testBrokenBlobsAreSkippedNotFatal() throws {
        let chat = try CursorFixture.Chat(name: "坏了一块")
        chat.turns = [.agent(user: "问", steps: [Data([0x0A, 0xFF, 0xFF]), F.assistant("答")])]
        try chat.save()
        let items = try transcript(of: chat)
        XCTAssertEqual(items.map(\.id), ["0.u", "0.1"])
    }

    // MARK: - 分页与跟随

    private func pager(for path: String, host: SQLiteTestHost, clock: CursorTestClock = CursorTestClock()) -> CursorTranscriptPager {
        CursorTranscriptPager(reader: SQLiteRemoteReader(provider: host, path: path), pageItems: 10, now: { clock.now })
    }

    func testPagesBackwardsInMemory() async throws {
        let chat = try CursorFixture.Chat(name: "长对话")
        chat.turns = (0..<12).map { .agent(user: "问题 \($0)", steps: [F.assistant("回答 \($0)")]) }
        try chat.save()
        let host = try await host(with: [(F.storePath(), chat)])
        let pager = pager(for: F.storePath(), host: host)

        var collected: [AgentTranscriptItem] = []
        var pages = 0
        var reachedStart = false
        while !reachedStart {
            let page = try await pager.loadPrevious()
            collected = page.items + collected
            reachedStart = page.reachedStart
            pages += 1
        }
        XCTAssertEqual(pages, 3)
        XCTAssertEqual(collected.count, 24)
        XCTAssertEqual(collected.first?.id, "0.u")
        XCTAssertEqual(collected.last?.id, "11.0")
        // 整份只读了一次。
        let mainReads = await host.reads.filter { $0.path == F.storePath() }.count
        XCTAssertEqual(mainReads, 1)
    }

    func testFollowAppendsNewTurnsAndLateToolResults() async throws {
        let chat = try CursorFixture.Chat(name: "开着的会话")
        // 两个并行的调用，都还没有结果。
        chat.turns = [.agent(user: "并行跑两个命令", steps: [F.shell("make a"), F.shell("make b")])]
        try chat.save()
        let host = try await host(with: [(F.storePath(), chat)])
        let pager = pager(for: F.storePath(), host: host)
        let first = try await pager.loadPrevious()
        XCTAssertEqual(first.items.map(\.id), ["0.u", "0.0", "0.1"])
        let unchanged = try await pager.loadNewer()
        XCTAssertEqual(unchanged, .unchanged)

        // 结果先后回来、又多了一句回答。
        chat.turns = [.agent(user: "并行跑两个命令", steps: [F.shell("make a", stdout: "a 好了"), F.shell("make b", stdout: "b 好了"),
                                                           F.assistant("两个都好了")])]
        try chat.save()
        await host.install(try chat.snapshot(), at: F.storePath(), mtime: F.createdAt.addingTimeInterval(5))
        let growth = try await pager.loadNewer()
        guard case .appended(let fresh, let hasMore) = growth else { return XCTFail("应该接上新内容，实际 \(growth)") }
        XCTAssertFalse(hasMore)
        XCTAssertEqual(fresh.map(\.id), ["0.0.r", "0.1.r", "0.2"])

        // 新的一轮。
        chat.turns.append(.agent(user: "再来", steps: []))
        try chat.save()
        await host.install(try chat.snapshot(), at: F.storePath(), mtime: F.createdAt.addingTimeInterval(10))
        let next = try await pager.loadNewer()
        XCTAssertEqual(next, .appended([AgentTranscriptItem(id: "1.u", kind: .userText("再来"))], hasMore: false))
    }

    func testFollowReplacesWhenTheConversationWasRewritten() async throws {
        let chat = try basicChat()
        let host = try await host(with: [(F.storePath(), chat)])
        let pager = pager(for: F.storePath(), host: host)
        _ = try await pager.loadPrevious()

        // 同一条（同一个位置）的回答改了：对不上，整份重来。
        chat.turns = [.agent(user: "帮我看看登录为什么失败", steps: [F.thinking("换了个想法")])]
        try chat.save()
        await host.install(try chat.snapshot(), at: F.storePath(), mtime: F.createdAt.addingTimeInterval(5))
        let growth = try await pager.loadNewer()
        XCTAssertEqual(growth, .replaced)
        let reloaded = try await pager.loadPrevious()
        XCTAssertEqual(reloaded.items.map(\.id), ["0.u", "0.0"])
        XCTAssertTrue(reloaded.reachedStart)
    }

    func testFollowReplacesWhenTheFileWasSwapped() async throws {
        let chat = try basicChat()
        let host = try await host(with: [(F.storePath(), chat)])
        let pager = pager(for: F.storePath(), host: host)
        _ = try await pager.loadPrevious()

        let other = try CursorFixture.Chat(name: "另一个")
        other.turns = [.agent(user: "完全不同的会话", steps: [])]
        try other.save()
        await host.install(try other.snapshot(), at: F.storePath(), mtime: F.createdAt.addingTimeInterval(5))
        let growth = try await pager.loadNewer()
        XCTAssertEqual(growth, .replaced)
    }

    func testFollowDoesNotRebuildLargeDatabasesEveryPoll() async throws {
        XCTAssertEqual(CursorTranscriptPager.rebuildInterval(forBytes: 1_000_000), .zero)
        XCTAssertEqual(CursorTranscriptPager.rebuildInterval(forBytes: 16 * 1024 * 1024), .seconds(4))
        XCTAssertEqual(CursorTranscriptPager.rebuildInterval(forBytes: 1 << 30), .seconds(15))

        // 不变的时候每次只列一次目录，一个字节都不读。
        let chat = try basicChat()
        let host = try await host(with: [(F.storePath(), chat)])
        let pager = pager(for: F.storePath(), host: host)
        _ = try await pager.loadPrevious()
        await host.clearCounters()
        for _ in 0..<5 { _ = try await pager.loadNewer() }
        let reads = await host.reads
        let lists = await host.lists
        XCTAssertTrue(reads.isEmpty)
        XCTAssertEqual(lists.count, 5)
    }

    func testFollowWaitsBetweenRebuildsOfABigDatabase() async throws {
        let chat = try basicChat()
        // 一个没人引用的大 blob 把库撑到 17 MB（会话里贴过大文件就会这样）。
        try chat.database.run("INSERT INTO blobs (id, data) VALUES (?, ?)", ["big", Data(count: 17 * 1024 * 1024)])
        let host = try await host(with: [(F.storePath(), chat)])
        let clock = CursorTestClock()
        let pager = pager(for: F.storePath(), host: host, clock: clock)
        _ = try await pager.loadPrevious()

        chat.turns.append(.agent(user: "又问了一句", steps: []))
        try chat.save()
        await host.install(try chat.snapshot(), at: F.storePath(), mtime: F.createdAt.addingTimeInterval(5))
        await host.clearCounters()
        clock.advance(.seconds(1))
        let soon = try await pager.loadNewer()
        XCTAssertEqual(soon, .unchanged)
        let lists = await host.lists
        XCTAssertTrue(lists.isEmpty, "大库在间隔内连目录都不该列")

        clock.advance(.seconds(4))
        let later = try await pager.loadNewer()
        XCTAssertEqual(later, .appended([AgentTranscriptItem(id: "1.u", kind: .userText("又问了一句"))], hasMore: false))
    }

    func testDifferenceRules() {
        func item(_ id: String, _ kind: AgentTranscriptItem.Kind = .assistantText("x")) -> AgentTranscriptItem {
            AgentTranscriptItem(id: id, kind: kind)
        }
        let result = AgentTranscriptItem.Kind.toolResult(AgentToolResult(toolUseID: "a", content: AgentClippedText("ok", limit: 10),
                                                                          isError: false, imageCount: 0))
        let old = [item("1"), item("2"), item("3")]
        // 没交出去的那段（start = 1 之前）新出现的结果留给往前翻。
        XCTAssertEqual(CursorTranscriptPager.difference(old: old, new: [item("1"), item("1.r", result), item("2"), item("3"), item("4")],
                                                        start: 1),
                       .appended(fresh: [item("4")], start: 2))
        // 中间插进来的结果照常交出去。
        XCTAssertEqual(CursorTranscriptPager.difference(old: old, new: [item("1"), item("2"), item("2.r", result), item("3")], start: 0),
                       .appended(fresh: [item("2.r", result)], start: 0))
        // 中间插进来的不是结果：重来。
        XCTAssertEqual(CursorTranscriptPager.difference(old: old, new: [item("1"), item("1.5"), item("2"), item("3")], start: 0),
                       .replaced)
        // 少了一条、改了一条、顺序变了：重来。
        XCTAssertEqual(CursorTranscriptPager.difference(old: old, new: [item("1"), item("3")], start: 0), .replaced)
        XCTAssertEqual(CursorTranscriptPager.difference(old: old, new: [item("1"), item("2", .assistantText("y")), item("3")], start: 0),
                       .replaced)
        XCTAssertEqual(CursorTranscriptPager.difference(old: old, new: [item("2"), item("1"), item("3")], start: 0), .replaced)
        // 原来是空的。
        XCTAssertEqual(CursorTranscriptPager.difference(old: [], new: [item("1")], start: 0), .appended(fresh: [item("1")], start: 0))
    }

    // MARK: - 其余

    func testSearchAndSubagentsAreNotSupported() async throws {
        let source = CursorHistorySource(provider: SQLiteTestHost(home: F.home))
        let query = try AgentHistorySearchQuery.validate("登录").get()
        do {
            try await source.search(query, in: [], limits: .standard) { _ in }
            XCTFail()
        } catch {
            XCTAssertEqual(error as? AgentHistorySearchError, .cannotExecute)
        }
        let project = AgentHistoryProject(id: F.workspaceHash, path: F.chatsRoot + "/" + F.workspaceHash, modifiedAt: nil,
                                          directory: F.workspace, tool: .cursor)
        let file = AgentHistorySessionFile(sessionID: F.sessionID, project: project, path: F.storePath(), size: 1, modifiedAt: Date())
        let subagents = try await source.subagents(of: .session(file))
        XCTAssertEqual(subagents, [])
    }

    func testCommands() {
        let source = CursorHistorySource(provider: SQLiteTestHost(home: F.home))
        XCTAssertEqual(source.resumeCommand(sessionID: F.sessionID, directory: F.workspace),
                       "cd -- '/home/user/projects/demo' && cursor-agent --resume \(F.sessionID)")
        XCTAssertEqual(source.resumeCommand(sessionID: F.sessionID, directory: "/home/user/it's a 项目"),
                       #"cd -- '/home/user/it'\''s a 项目' && cursor-agent --resume "# + F.sessionID)
        XCTAssertEqual(source.newSessionCommand(directory: F.workspace), "cd -- '/home/user/projects/demo' && cursor-agent")
        // ID 不是 UUID 的形状、目录不是绝对路径或带换行：不给命令。
        XCTAssertNil(source.resumeCommand(sessionID: "abc; rm -rf ~", directory: F.workspace))
        XCTAssertNil(source.resumeCommand(sessionID: F.sessionID + " --force", directory: F.workspace))
        XCTAssertNil(source.resumeCommand(sessionID: F.sessionID, directory: "projects/demo"))
        XCTAssertNil(source.resumeCommand(sessionID: F.sessionID, directory: "/home/user\n/x"))
        XCTAssertNil(source.newSessionCommand(directory: "~/demo"))
    }
}

/// 测试用的钟：手动拨。
final class CursorTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = ContinuousClock.now
    var now: ContinuousClock.Instant { lock.withLock { current } }
    func advance(_ duration: Duration) { lock.withLock { current += duration } }
}
