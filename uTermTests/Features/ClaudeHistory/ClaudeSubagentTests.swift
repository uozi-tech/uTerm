import XCTest
@testable import uTerm

/// 子代理的记录：派子代理的调用对上 `<会话>/subagents/agent-<ID>.jsonl`，点进去和主对话同一套显示，可以一层层往里进。
/// 记录全是手写的假数据（`ClaudeFixture`）。
@MainActor
final class ClaudeSubagentTests: XCTestCase {
    private let root = "/home/user/.claude/projects"
    private let project = "-home-user-projects-demo"
    private let sessionID = ClaudeFixture.sessionID
    private var projectDir: String { "\(root)/\(project)" }
    private var sessionPath: String { "\(projectDir)/\(sessionID).jsonl" }
    private var subagentsDir: String { "\(projectDir)/\(sessionID)/subagents" }

    private struct Subagent {
        let id: String
        let lines: [String]
        /// 派它的那次调用；nil = 没有 meta 文件。
        var metaToolUseID: String?
        var description = "子任务"
    }

    /// 一个项目、一份会话；`subagents` 为 nil 时没有 `subagents/` 目录。`extra` 是目录里别的东西。
    private func makeTree(main: [String], subagents: [Subagent]?, extra: [RemoteEntry] = []) async -> MockSFTP {
        let mainData = ClaudeFixture.file(main)
        var tree: [String: [RemoteEntry]] = [
            root: [ClaudeFixture.entry(project, directory: true)],
            projectDir: [ClaudeFixture.entry("\(sessionID).jsonl", size: UInt64(mainData.count)),
                         ClaudeFixture.entry(sessionID, directory: true)],
        ]
        let sftp = MockSFTP()
        await sftp.setFile(sessionPath, data: mainData, mtime: Date())
        if let subagents {
            var entries = extra
            for (index, agent) in subagents.enumerated() {
                let data = ClaudeFixture.file(agent.lines)
                let mtime = Date(timeIntervalSince1970: 1_000_000 + TimeInterval(index))
                entries.append(ClaudeFixture.entry("agent-\(agent.id).jsonl", size: UInt64(data.count), mtime: mtime))
                await sftp.setFile("\(subagentsDir)/agent-\(agent.id).jsonl", data: data, mtime: mtime)
                if let toolUseID = agent.metaToolUseID {
                    let meta = ClaudeFixture.subagentMeta(toolUseID: toolUseID, description: agent.description)
                    entries.append(ClaudeFixture.entry("agent-\(agent.id).meta.json", size: UInt64(meta.count), mtime: mtime))
                    await sftp.setFile("\(subagentsDir)/agent-\(agent.id).meta.json", data: meta, mtime: mtime)
                }
            }
            tree["\(projectDir)/\(sessionID)"] = [ClaudeFixture.entry("subagents", directory: true)]
            tree[subagentsDir] = entries
        }
        await sftp.setTree(tree)
        return sftp
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<300 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// 打开那份会话的主对话，等它读完。
    private func openSession(_ sftp: MockSFTP) async throws -> (AgentHistoryModel, AgentTranscriptModel) {
        let model = AgentHistoryModel(source: ClaudeHistorySource(provider: sftp), preferredDirectory: ClaudeFixture.cwd)
        await model.start()
        await waitUntil { !model.hasMore }
        model.select(try XCTUnwrap(model.files.first))
        let transcript = try XCTUnwrap(model.transcript)
        await waitUntil { transcript.reachedStart }
        return (model, transcript)
    }

    private func call(_ id: String, in transcript: AgentTranscriptModel) -> AgentToolCall? {
        for item in transcript.items {
            if case .toolCall(let call) = item.kind, call.toolUseID == id { return call }
        }
        return nil
    }

    private func readPaths(_ sftp: MockSFTP) async -> [String] {
        await sftp.rangeReads.map(\.path)
    }

    // MARK: - 解析

    func testParserMarksSpawnCallsAndReportedAgentIDs() {
        let assistant = ClaudeFixture.assistant(ClaudeFixture.spawn(id: "toolu_a", description: "查日志", type: "Explore"))
        let items = ClaudeTranscriptParser.items(fromJSON: Data(assistant.utf8), idPrefix: "0")
        guard case .toolCall(let call) = items.first?.kind else { return XCTFail("没解析出调用") }
        XCTAssertEqual(call.spawn, AgentSpawnRequest(description: "查日志", agentType: "Explore"))
        XCTAssertEqual(call.summary, "查日志")

        let legacy = ClaudeFixture.assistant(ClaudeFixture.spawn(id: "toolu_t", description: "旧版", type: nil, name: "Task"))
        guard case .toolCall(let old) = ClaudeTranscriptParser.items(fromJSON: Data(legacy.utf8), idPrefix: "1").first?.kind
        else { return XCTFail("没解析出旧版调用") }
        XCTAssertEqual(old.spawn, AgentSpawnRequest(description: "旧版", agentType: nil))

        let bash = ClaudeFixture.assistant(ClaudeFixture.toolUse(id: "toolu_b", name: "Bash", input: #"{"command":"ls"}"#))
        guard case .toolCall(let plain) = ClaudeTranscriptParser.items(fromJSON: Data(bash.utf8), idPrefix: "2").first?.kind
        else { return XCTFail("没解析出 Bash") }
        XCTAssertNil(plain.spawn)

        let result = ClaudeFixture.spawnResult(id: "toolu_a", agentID: "a1b2c3")
        guard case .toolResult(let reported) = ClaudeTranscriptParser.items(fromJSON: Data(result.utf8), idPrefix: "3").first?.kind
        else { return XCTFail("没解析出结果") }
        XCTAssertEqual(reported.spawnedAgentID, "a1b2c3")
        XCTAssertEqual(reported.content.text, "子代理做完了")
    }

    /// 子代理自己的记录每行都是 `isSidechain`：主对话里不显示，读子代理的记录时照常显示。
    func testSidechainLinesShowOnlyInSubagentTranscripts() {
        let line = ClaudeReverseLineScanner.Line(offset: 0, length: 0,
                                                 bytes: Data(ClaudeFixture.sidechainUser("去查日志", agentID: "a1").utf8),
                                                 isTruncated: false)
        XCTAssertEqual(ClaudeTranscriptParser.items(from: line), [])
        XCTAssertEqual(ClaudeTranscriptParser.items(from: line, includesSidechain: true).map(\.kind), [.userText("去查日志")])
    }

    // MARK: - 对上记录

    /// 有 meta 文件、结果里没报 ID：读 meta 对上。
    func testLinksThroughMetaFile() async throws {
        let sftp = await makeTree(main: [
            ClaudeFixture.userText("帮我查"),
            ClaudeFixture.assistant(ClaudeFixture.spawn(id: "toolu_1", description: "查日志")),
            ClaudeFixture.spawnResult(id: "toolu_1", agentID: nil),
        ], subagents: [Subagent(id: "a111", lines: [ClaudeFixture.sidechainUser("去查日志", agentID: "a111")],
                                metaToolUseID: "toolu_1")])
        let (_, transcript) = try await openSession(sftp)
        await waitUntil { !transcript.subagentLinks.isEmpty }
        let link = try XCTUnwrap(transcript.subagentLink(for: try XCTUnwrap(call("toolu_1", in: transcript))))
        XCTAssertEqual(link.file.agentID, "a111")
        XCTAssertEqual(link.description, "查日志")
        XCTAssertEqual(link.agentType, "general-purpose")
        XCTAssertTrue(link.file.hasInfo)
    }

    /// 没有 meta 文件：靠结果里的 `toolUseResult.agentId` 对上，一份 meta 都不读。
    func testLinksThroughReportedAgentIDWithoutMeta() async throws {
        let sftp = await makeTree(main: [
            ClaudeFixture.userText("帮我查"),
            ClaudeFixture.assistant(ClaudeFixture.spawn(id: "toolu_1", description: "查日志")),
            ClaudeFixture.spawnResult(id: "toolu_1", agentID: "b222"),
        ], subagents: [Subagent(id: "b222", lines: [ClaudeFixture.sidechainUser("去查日志", agentID: "b222")])])
        let (_, transcript) = try await openSession(sftp)
        await waitUntil { !transcript.subagentLinks.isEmpty }
        XCTAssertEqual(transcript.subagentLinks["toolu_1"]?.file.agentID, "b222")
        let reads = await readPaths(sftp)
        XCTAssertFalse(reads.contains { $0.hasSuffix(".meta.json") }, "能靠结果对上就不该读 meta")
    }

    /// 旧版本的工具名 `Task`。
    func testLegacyTaskToolName() async throws {
        let sftp = await makeTree(main: [
            ClaudeFixture.assistant(ClaudeFixture.spawn(id: "toolu_t", description: "旧版的子任务", type: nil, name: "Task")),
            ClaudeFixture.spawnResult(id: "toolu_t", agentID: "c333"),
        ], subagents: [Subagent(id: "c333", lines: [ClaudeFixture.sidechainUser("旧版", agentID: "c333")])])
        let (_, transcript) = try await openSession(sftp)
        await waitUntil { !transcript.subagentLinks.isEmpty }
        let link = try XCTUnwrap(transcript.subagentLinks["toolu_t"])
        XCTAssertEqual(link.file.agentID, "c333")
        XCTAssertEqual(link.description, "旧版的子任务")
        XCTAssertNil(link.agentType)
    }

    /// 子代理里再派子代理：两层都点得进去，一层层返回；子代理的记录不能「继续」。
    func testNestedSubagentsOpenAndCloseLevelByLevel() async throws {
        let sftp = await makeTree(main: [
            ClaudeFixture.userText("大任务"),
            ClaudeFixture.assistant(ClaudeFixture.spawn(id: "toolu_outer", description: "第一层")),
            ClaudeFixture.spawnResult(id: "toolu_outer", agentID: "outer1"),
        ], subagents: [
            Subagent(id: "outer1", lines: [
                ClaudeFixture.sidechainUser("做第一层", agentID: "outer1"),
                ClaudeFixture.sidechainAssistant(ClaudeFixture.textBlock("我再派一个"), agentID: "outer1", uuid: "s-a-0"),
                ClaudeFixture.sidechainAssistant(ClaudeFixture.spawn(id: "toolu_inner", description: "第二层", type: "Explore"),
                                                 agentID: "outer1"),
            ], metaToolUseID: "toolu_outer", description: "第一层"),
            // 第二层的结果还没写（还在跑）：只能靠 meta 对上。
            Subagent(id: "inner2", lines: [
                ClaudeFixture.sidechainUser("做第二层", agentID: "inner2"),
                ClaudeFixture.sidechainAssistant(ClaudeFixture.textBlock("第二层做完了"), agentID: "inner2"),
            ], metaToolUseID: "toolu_inner", description: "第二层"),
        ])
        let (model, transcript) = try await openSession(sftp)
        await waitUntil { transcript.subagentLinks["toolu_outer"] != nil }
        let outerLink = try XCTUnwrap(transcript.subagentLinks["toolu_outer"])
        XCTAssertNil(transcript.subagentLinks["toolu_inner"], "第二层是第一层派的，不该挂在主对话上")

        model.openSubagent(outerLink)
        let outer = try XCTUnwrap(model.displayedTranscript)
        XCTAssertTrue(outer !== transcript)
        XCTAssertEqual(outer.subagent?.file.agentID, "outer1")
        XCTAssertEqual(outer.path, "\(subagentsDir)/agent-outer1.jsonl")
        await waitUntil { outer.reachedStart }
        XCTAssertEqual(outer.items.first?.kind, .userText("做第一层"))
        await waitUntil { outer.subagentLinks["toolu_inner"] != nil }
        let innerLink = try XCTUnwrap(outer.subagentLinks["toolu_inner"])
        XCTAssertEqual(innerLink.agentType, "Explore")

        model.openSubagent(innerLink)
        XCTAssertEqual(model.subagentStack.count, 2)
        let inner = try XCTUnwrap(model.displayedTranscript)
        await waitUntil { inner.reachedStart }
        XCTAssertEqual(inner.items.map(\.kind), [.userText("做第二层"), .assistantText("第二层做完了")])

        model.closeSubagent()
        XCTAssertTrue(model.displayedTranscript === outer)
        model.closeSubagent()
        XCTAssertTrue(model.displayedTranscript === transcript)
        model.closeSubagent()
        XCTAssertTrue(model.displayedTranscript === transcript, "已经在最外层，再返回没有效果")

        // 换一份会话：一层层的子代理都收掉。
        model.openSubagent(outerLink)
        model.select(nil)
        XCTAssertTrue(model.subagentStack.isEmpty)
    }

    /// 没有 `subagents/` 目录（没派过、或者被清了）：不给入口，不报错，只列一次目录。
    func testNoSubagentsDirectoryGivesNoEntry() async throws {
        let sftp = await makeTree(main: [
            ClaudeFixture.assistant(ClaudeFixture.spawn(id: "toolu_1", description: "查日志")),
            ClaudeFixture.spawnResult(id: "toolu_1", agentID: "gone"),
        ], subagents: nil)
        let (_, transcript) = try await openSession(sftp)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(transcript.subagentLinks.isEmpty)
        XCTAssertNil(transcript.errorMessage)
        let lists = await sftp.listCalls.filter { $0.hasSuffix("/subagents") }
        XCTAssertEqual(lists, [subagentsDir])
    }

    /// 目录里别的东西（`*.prefix.json`、`*.forked-skill.json`、`workflows/`）不当成子代理；记录被清掉的那个也不给入口。
    func testUnrelatedFilesInSubagentsDirectoryAreIgnored() async throws {
        let extra = [ClaudeFixture.entry("agent-x9.prefix.json", size: 10),
                     ClaudeFixture.entry("agent-x9.forked-skill.json", size: 10),
                     ClaudeFixture.entry("workflows", directory: true),
                     ClaudeFixture.entry("agent-dir.jsonl", directory: true),
                     ClaudeFixture.entry("notes.txt", size: 3)]
        let sftp = await makeTree(main: [
            ClaudeFixture.assistant(ClaudeFixture.spawn(id: "toolu_1", description: "有记录的")),
            ClaudeFixture.spawnResult(id: "toolu_1", agentID: "d444"),
            ClaudeFixture.assistant(ClaudeFixture.spawn(id: "toolu_2", description: "记录被清了"), uuid: "a-2"),
            ClaudeFixture.spawnResult(id: "toolu_2", agentID: "x9"),
        ], subagents: [Subagent(id: "d444", lines: [ClaudeFixture.sidechainUser("做", agentID: "d444")])], extra: extra)
        let source = ClaudeHistorySource(provider: sftp)
        let projects = try await source.projects()
        let sessions = try await source.sessions(in: try XCTUnwrap(projects.first))
        let listed = try await source.subagents(of: .session(try XCTUnwrap(sessions.first)))
        XCTAssertEqual(listed.map(\.agentID), ["d444"])

        let (_, transcript) = try await openSession(sftp)
        await waitUntil { transcript.subagentLinks["toolu_1"] != nil }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(Array(transcript.subagentLinks.keys), ["toolu_1"])
    }

    /// 懒：列会话列表不碰 `subagents/`；一份对话派了 60 个子代理、只有一个要靠 meta 对上时，不把 60 份 meta 都读了。
    func testSubagentLookupIsLazyAndBounded() async throws {
        var main = [ClaudeFixture.userText("派很多子代理")]
        var agents: [Subagent] = []
        for index in 0..<60 {
            let toolID = "toolu_\(index)", agentID = String(format: "e%03d", index)
            main.append(ClaudeFixture.assistant(ClaudeFixture.spawn(id: toolID, description: "第 \(index) 个"), uuid: "a-\(index)"))
            // 最后一个还没有结果（还在跑）：只能靠 meta。
            if index < 59 { main.append(ClaudeFixture.spawnResult(id: toolID, agentID: agentID)) }
            agents.append(Subagent(id: agentID, lines: [ClaudeFixture.sidechainUser("做 \(index)", agentID: agentID)],
                                   metaToolUseID: toolID))
        }
        let sftp = await makeTree(main: main, subagents: agents)
        let model = AgentHistoryModel(source: ClaudeHistorySource(provider: sftp), preferredDirectory: ClaudeFixture.cwd)
        await model.start()
        await waitUntil { !model.hasMore }
        let listedBeforeOpen = await sftp.listCalls.filter { $0.contains("/subagents") }
        XCTAssertEqual(listedBeforeOpen, [], "列表阶段不该去列子代理的目录")

        model.select(try XCTUnwrap(model.files.first))
        let transcript = try XCTUnwrap(model.transcript)
        // 一页不够：一页页往前翻到头（界面是往上滚到哪翻到哪）。
        await waitUntil { !transcript.isLoading && !transcript.items.isEmpty }
        while !transcript.reachedStart { await transcript.loadEarlier() }
        await waitUntil { transcript.subagentLinks.count == 60 }
        XCTAssertEqual(transcript.subagentLinks["toolu_59"]?.file.agentID, "e059")
        let metaReads = await readPaths(sftp).filter { $0.hasSuffix(".meta.json") }
        XCTAssertLessThanOrEqual(metaReads.count, AgentTranscriptModel.infoConcurrency,
                                 "最新的那个第一批就该对上，不该接着读")
    }
}
