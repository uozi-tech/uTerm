import XCTest
@testable import uTerm

/// Codex 数据源：列表、项目、信息、对话、子代理、命令。主机是 `MockSFTP`（跑不了命令，所以都走 SFTP 那条退路），
/// 走主机命令的那条见 `CodexHistoryShellTests`。
final class CodexHistorySourceTests: XCTestCase {
    private typealias F = CodexFixture
    private let other = "019a0000-2222-7333-8444-555566667777"
    private let desktop = "019a0000-3333-7444-8555-666677778888"
    private let child = "019a0000-4444-7555-8666-777788889999"
    private let guardian = "019a0000-5555-7666-8777-888899990000"

    private func date(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

    /// 一棵有各种记录的主机：命令行会话两份（同一个目录）、另一个目录只有桌面版的、子代理、审查、压缩的、回退出来的第二份。
    private func makeHost() async -> MockSFTP {
        let spawnParent = F.threadID
        return await F.host([
            (F.path(id: F.threadID), F.session(), date(5_000)),
            (F.path(id: other, day: "19"), F.session(id: other, prompt: "第二个会话"), date(4_000)),
            (F.path(id: desktop, day: "18"), F.session(id: desktop, cwd: "/home/user/desktop-only", originator: "Codex Desktop"), date(3_000)),
            (F.path(id: child), F.file([F.meta(id: child, source: F.spawnSource(parent: spawnParent, path: "/root/fix_tests"),
                                              threadSource: "subagent", parent: spawnParent),
                                       F.user("父会话的上下文", ordinal: 1), F.user("子代理自己的活", ordinal: 5)]), date(4_500)),
            (F.path(id: guardian), F.file([F.meta(id: guardian, source: #"{"subagent":{"other":"guardian"}}"#,
                                                 threadSource: "guardian_review", parent: spawnParent), F.user("审查")]), date(4_600)),
            ("\(F.root)/2026/11/01/rollout-2026-11-01T09-00-00-\(CodexZstdFixture.threadID).jsonl.zst", CodexZstdFixture.small, date(1_000)),
        ], extra: ["\(F.root)/2026/11/20": [F.entry(".rollout-materialize-x.jsonl", size: 3), F.entry("notes.txt", size: 3)]])
    }

    func testListsCommandLineProjectsAndTheirSessions() async throws {
        let source = CodexHistorySource(provider: await makeHost())
        let projects = try await source.projects()
        XCTAssertEqual(projects.map(\.id), [F.cwd, CodexZstdFixture.cwd], "只有桌面版会话的目录不算项目，新的在前")
        XCTAssertTrue(projects.allSatisfy { $0.tool == .codex && $0.directory == $0.id && $0.path == F.root })

        let demo = try XCTUnwrap(projects.first)
        let sessions = try await source.sessions(in: demo)
        XCTAssertEqual(sessions.map(\.sessionID), [F.threadID, other], "子代理、审查不列，新的在前")
        XCTAssertEqual(sessions.first?.tool, .codex)
        let all = await source.allSessions(in: projects)
        XCTAssertEqual(all.map(\.sessionID), [F.threadID, other, CodexZstdFixture.threadID])
        XCTAssertTrue(all.last?.path.hasSuffix(".jsonl.zst") == true)

        let nested = await source.project(containing: F.cwd + "/src/views", among: projects)
        XCTAssertEqual(nested?.id, F.cwd)
        let slash = await source.project(containing: F.cwd + "/", among: projects)
        XCTAssertEqual(slash?.id, F.cwd)
        let sibling = await source.project(containing: "/home/user/projects/demo2", among: projects)
        XCTAssertNil(sibling, "只是名字开头一样")
        let outside = await source.project(containing: "/srv", among: projects)
        XCTAssertNil(outside)
    }

    func testNoCodexDirectoryMeansEmpty() async throws {
        let projects = try await CodexHistorySource(provider: MockSFTP()).projects()
        XCTAssertEqual(projects, [])
    }

    func testMetadataTitlesBranchActivityAndListing() async throws {
        let sftp = await makeHost()
        let names = Data(#"{"id":"\#(other)","thread_name":"我起的名字","updated_at":"2026-11-20T00:00:00Z"}"#.utf8 + [0x0A])
        await sftp.setFile("\(F.home)/.codex/session_index.jsonl", data: names, mtime: date(1))
        let source = CodexHistorySource(provider: sftp)
        let projects = try await source.projects()
        let sessions = try await source.sessions(in: try XCTUnwrap(projects.first))

        let first = try await source.metadata(for: sessions[0])
        XCTAssertEqual(first.title, "帮我修复登录页", "没有名字：第一句你说的话（注入的不算）")
        XCTAssertTrue(first.isListed)
        XCTAssertEqual(first.gitBranch, "main")
        XCTAssertEqual(first.resumeDirectory, F.cwd)
        XCTAssertEqual(first.lastDirectory, F.cwd + "/src", "最后一个 turn_context 的目录")
        XCTAssertEqual(first.lastActivity, ClaudeTimestamp.parse("2026-11-20T10:00:03.000Z"), "最后一行的时间")
        let named = try await source.metadata(for: sessions[1])
        XCTAssertEqual(named.title, "我起的名字", "session_index 里的名字优先")

        // 压缩的：标题、分支照样有，最后活动时间用修改时间。
        let everything = await source.allSessions(in: projects)
        let archived = try XCTUnwrap(everything.last)
        let info = try await source.metadata(for: archived)
        XCTAssertEqual(info.title, "压缩记录里的第一句话 Zebra")
        XCTAssertEqual(info.gitBranch, "feature/zip")
        XCTAssertTrue(info.isListed)
        XCTAssertEqual(info.resumeDirectory, CodexZstdFixture.cwd)
        XCTAssertEqual(info.lastActivity, ClaudeTimestamp.parse("2026-11-01T09:00:09.000Z"), "小文件整份解开了，用记录里的时间")

        // 读过的走缓存。
        await sftp.clearRangeReads()
        _ = try await source.metadata(for: sessions[0])
        let reads = await sftp.rangeReads.count
        XCTAssertEqual(reads, 0)
    }

    /// 桌面版的会话进列表但不显示；只有注入内容、没有一句对话的小会话也不显示。
    func testHiddenSessions() async throws {
        let empty = "019a0000-6666-7777-8888-999900001111"
        let sftp = await F.host([
            (F.path(id: F.threadID), F.session(), date(5_000)),
            (F.path(id: desktop), F.session(id: desktop, originator: "Codex Desktop"), date(4_000)),
            (F.path(id: empty), F.file([F.meta(id: empty), F.developer("x"), F.injected]), date(3_000)),
        ])
        let source = CodexHistorySource(provider: sftp)
        let projects = try await source.projects()
        let sessions = try await source.sessions(in: try XCTUnwrap(projects.first))
        XCTAssertEqual(sessions.count, 3)
        var listed: [String] = []
        for file in sessions {
            let info = try await source.metadata(for: file)
            if info.isListed { listed.append(file.sessionID) }
        }
        XCTAssertEqual(listed, [F.threadID])
    }

    /// 回退过的线程有好几份（`<ID>_<另一个 UUID>`）：只列最新的一份。明文与压缩同时在时用明文的。
    func testDuplicateRecordsOfOneThread() async throws {
        let base = F.path(id: F.threadID)
        let segment = base.replacingOccurrences(of: F.threadID, with: F.threadID + "_019a0000-9999-7999-8999-999999999999")
        let sftp = await F.host([
            (base, F.session(), date(1_000)),
            (segment, F.session(prompt: "回退后的"), date(2_000)),
            (base + ".zst", CodexZstdFixture.small, date(500)),
        ])
        let source = CodexHistorySource(provider: sftp)
        let projects = try await source.projects()
        let sessions = await source.allSessions(in: projects)
        XCTAssertEqual(sessions.map(\.path), [segment])
        let files = try await source.listRecordFiles(root: F.root)
        XCTAssertEqual(Set(files.map(\.path)), [base, segment], "同一份的明文与压缩：用明文的")
    }

    func testSubagentsAreFoundThroughTheirParent() async throws {
        let source = CodexHistorySource(provider: await makeHost())
        let projects = try await source.projects()
        let sessions = try await source.sessions(in: try XCTUnwrap(projects.first))
        let parent = try XCTUnwrap(sessions.first)
        let subagents = try await source.subagents(of: .session(parent))
        XCTAssertEqual(subagents.map(\.agentID), ["fix_tests"], "审查不是派出来的子代理")
        XCTAssertEqual(subagents.first?.tool, .codex)
        let spawned = try XCTUnwrap(subagents.first)
        let none = try await source.subagents(of: .subagent(spawned))
        XCTAssertEqual(none, [])
        let info = await source.info(of: spawned)
        XCTAssertNil(info)
    }

    func testSubagentTranscriptSkipsInheritedContext() async throws {
        let parent = F.threadID
        let line = F.meta(id: child, source: F.spawnSource(parent: parent, path: "/root/a"), threadSource: "subagent", parent: parent)
            .replacingOccurrences(of: #""history_mode":"paginated""#, with: #""history_mode":"paginated","subagent_history_start_ordinal":4"#)
        let sftp = await F.host([(F.path(id: child), F.file([line, F.user("父会话的上下文", ordinal: 2), F.user("自己的", ordinal: 4)]), date(1))])
        let source = CodexHistorySource(provider: sftp)
        _ = try await source.projects()
        let pager = source.subagentTranscript(for: AgentSubagentFile(agentID: "a", path: F.path(id: child), size: nil,
                                                                     modifiedAt: nil, hasInfo: false, tool: .codex))
        let page = try await pager.loadPrevious()
        XCTAssertEqual(page.items.map(\.kind), [.userText("自己的")])
        XCTAssertTrue(page.reachedStart)
    }

    // MARK: 对话

    func testPlainTranscriptPagesAndFollows() async throws {
        var lines = [F.meta(), F.injected]
        for index in 0..<120 { lines.append(F.user("第 \(index) 句", ordinal: index + 1)) }
        let data = F.file(lines)
        let path = F.path(id: F.threadID)
        let sftp = await F.host([(path, data, date(1))])
        let source = CodexHistorySource(provider: sftp)
        let projects = try await source.projects()
        let listed = await source.allSessions(in: projects)
        let file = try XCTUnwrap(listed.first)
        let pager = source.transcript(for: file)
        var items: [AgentTranscriptItem] = []
        var reachedStart = false
        while !reachedStart {
            let page = try await pager.loadPrevious()
            items = page.items + items
            reachedStart = page.reachedStart
        }
        XCTAssertEqual(items.count, 120)
        XCTAssertEqual(items.first?.kind, .userText("第 0 句"))
        XCTAssertEqual(Set(items.map(\.id)).count, 120)

        // 会话还开着：长出来的接上。
        var grown = data
        grown.append(Data((F.assistant("新的回答") + "\n").utf8))
        await sftp.setFile(path, data: grown, mtime: date(2))
        let growth = try await pager.loadNewer()
        XCTAssertEqual(growth, .appended([AgentTranscriptItem(id: "\(data.count).0", kind: .assistantText("新的回答"),
                                                              timestamp: ClaudeTimestamp.parse("2026-11-20T10:00:02.000Z"))],
                                         hasMore: false))
    }

    func testCompressedTranscriptReadsEverythingAndDoesNotFollow() async throws {
        let path = "\(F.root)/2026/11/01/rollout-2026-11-01T09-00-00-\(CodexZstdFixture.threadID).jsonl.zst"
        let sftp = await F.host([(path, CodexZstdFixture.big, date(1))])
        let source = CodexHistorySource(provider: sftp)
        let projects = try await source.projects()
        let listed = await source.allSessions(in: projects)
        let file = try XCTUnwrap(listed.first)
        let pager = source.transcript(for: file)
        let page = try await pager.loadPrevious()
        XCTAssertEqual(page.items.last?.kind, .userText("很长的压缩记录里最后一句话"))
        let growth = try await pager.loadNewer()
        XCTAssertEqual(growth, .unchanged)

        let small = "\(F.root)/2026/11/02/rollout-2026-11-02T09-00-00-\(CodexZstdFixture.threadID).jsonl.zst"
        await sftp.setFile(small, data: CodexZstdFixture.small, mtime: date(1))
        let smallPager = CodexHistorySource.pager(provider: sftp, path: small, anchor: nil, minimumOrdinal: nil)
        let all = try await smallPager.loadPrevious()
        XCTAssertTrue(all.reachedStart)
        let assembled = AgentTranscriptAssembler.attachResults(all.items)
        XCTAssertEqual(assembled.map(\.role), [.user, .assistant, .assistant, .assistant])
        guard case .toolCall(let call) = assembled[2].kind else { return XCTFail() }
        XCTAssertEqual(call.summary, "src/zip.ts")
        XCTAssertEqual(call.result?.content.text, "Success. Updated the following files:\nM src/zip.ts")
    }

    /// 从某一行打开压缩的记录：先给那一行和它前面的，往后一页一页读到末尾。条目 ID 与从末尾读的一样。
    func testCompressedTranscriptAroundAnAnchor() async throws {
        let path = "\(F.root)/2026/11/01/rollout-x.jsonl.zst"
        let sftp = MockSFTP()
        await sftp.setFile(path, data: CodexZstdFixture.small, mtime: date(1))
        let plain = try CodexZstdStream.decompress(CodexZstdFixture.small)
        let needle = Data("压缩记录里的第一句话".utf8)
        let hit = try XCTUnwrap(plain.range(of: needle))
        let start = (plain[..<hit.lowerBound].lastIndex(of: 0x0A) ?? -1) + 1
        let end = plain[hit.upperBound...].firstIndex(of: 0x0A) ?? plain.count
        let anchor = AgentTranscriptAnchor(lineOffset: UInt64(start), lineLength: end - start)

        let pager = CodexCompressedPager(provider: sftp, path: path, anchor: anchor, pageItems: 1,
                                         lineParser: { CodexTranscriptParser.items(from: $0) })
        let first = try await pager.loadPrevious()
        XCTAssertEqual(first.items.last?.id, "\(start).0")
        XCTAssertEqual(first.items.last?.kind, .userText("压缩记录里的第一句话 Zebra"))
        var after: [AgentTranscriptItem] = []
        var more = true
        while more {
            guard case .appended(let items, let hasMore) = try await pager.loadNext() else { return XCTFail() }
            after += items
            more = hasMore
        }
        XCTAssertEqual(after.last?.kind, .assistantText("压缩记录里的回答 Zebra done"))
        let fromEndPager = CodexCompressedPager(provider: sftp, path: path, lineParser: { CodexTranscriptParser.items(from: $0) })
        let fromEnd = try await fromEndPager.loadPrevious().items
        XCTAssertEqual(first.items.map(\.id) + after.map(\.id), fromEnd.map(\.id))
    }

    func testCompressedTranscriptTooLargeOrDamaged() async throws {
        let sftp = MockSFTP()
        await sftp.setFile("/a.jsonl.zst", data: CodexZstdFixture.big, mtime: date(1))
        let pager = CodexCompressedPager(provider: sftp, path: "/a.jsonl.zst", maxDecodedBytes: 100_000,
                                         lineParser: { CodexTranscriptParser.items(from: $0) })
        do {
            _ = try await pager.loadPrevious()
            XCTFail("超过上限还打开了")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("codex resume"), error.localizedDescription)
        }
        let reads = await sftp.rangeReads.count
        XCTAssertEqual(reads, 1, "帧头写着原始大小，看一眼就不下载了")

        await sftp.setFile("/b.jsonl.zst", data: CodexZstdFixture.small.prefix(400), mtime: date(1))
        let damaged = CodexCompressedPager(provider: sftp, path: "/b.jsonl.zst", lineParser: { CodexTranscriptParser.items(from: $0) })
        do {
            _ = try await damaged.loadPrevious()
            XCTFail("坏的压缩记录也打开了")
        } catch {
            XCTAssertTrue(error is RemoteFileError)
        }
    }

    // MARK: 命令

    func testResumeAndNewSessionCommands() {
        let source = CodexHistorySource(provider: MockSFTP())
        XCTAssertEqual(source.resumeCommand(sessionID: F.threadID.uppercased(), directory: "/home/u/it's 项目"),
                       "cd -- '/home/u/it'\\''s 项目' && codex resume \(F.threadID)")
        XCTAssertNil(source.resumeCommand(sessionID: "019a0000; rm -rf ~", directory: "/a"))
        XCTAssertNil(source.resumeCommand(sessionID: F.threadID, directory: "relative"))
        XCTAssertNil(source.resumeCommand(sessionID: F.threadID, directory: "/a\nb"))
        XCTAssertEqual(source.newSessionCommand(directory: "/srv/app"), "cd -- '/srv/app' && codex")
        XCTAssertNil(source.newSessionCommand(directory: "/a\u{7F}"))
        XCTAssertEqual(source.tool, .codex)
        XCTAssertTrue(source.supportsSearch)
    }
}
