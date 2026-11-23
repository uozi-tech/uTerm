import CryptoKit
import XCTest
@testable import uTerm

/// vendor 的 libzstd（只有解压）：夹具是 zstd 命令行压的假记录。
final class CodexZstdTests: XCTestCase {
    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func testDecodesWholeFramesAndReadsTheDeclaredSize() throws {
        for (data, length, digest) in [(CodexZstdFixture.small, CodexZstdFixture.smallLength, CodexZstdFixture.smallSHA256),
                                       (CodexZstdFixture.big, CodexZstdFixture.bigLength, CodexZstdFixture.bigSHA256)] {
            XCTAssertTrue(CodexZstdStream.looksLikeZstd(data))
            XCTAssertEqual(CodexZstdStream.contentSize(ofFramePrefix: data.prefix(18)), UInt64(length))
            let decoded = try CodexZstdStream.decompress(data)
            XCTAssertEqual(decoded.count, length)
            XCTAssertEqual(sha256(decoded), digest)
        }
        XCTAssertFalse(CodexZstdStream.looksLikeZstd(Data("{\"timestamp\"".utf8)))
        XCTAssertNil(CodexZstdStream.contentSize(ofFramePrefix: Data("{}".utf8)))
    }

    /// 一块一块喂（下载时就是这样）和整段喂结果一样；每块都很小也行。
    func testStreamingInSmallPiecesGivesTheSameBytes() throws {
        let data = CodexZstdFixture.big
        for piece in [1, 7, 4096] {
            let stream = CodexZstdStream()
            var output = Data()
            var offset = 0
            while offset < data.count {
                output.append(try stream.decompress(data.subdata(in: offset..<min(data.count, offset + piece))))
                offset += piece
            }
            XCTAssertTrue(stream.isAtFrameEnd)
            XCTAssertEqual(sha256(output), CodexZstdFixture.bigSHA256, "每块 \(piece) 字节")
        }
    }

    func testTruncatedOrDamagedDataIsAnError() {
        let data = CodexZstdFixture.small
        XCTAssertThrowsError(try CodexZstdStream.decompress(data.prefix(data.count - 5))) {
            XCTAssertEqual($0 as? CodexZstdError, .corrupt)
        }
        var damaged = data
        damaged[30] ^= 0xFF
        damaged[31] ^= 0xFF
        XCTAssertThrowsError(try CodexZstdStream.decompress(damaged))
        XCTAssertThrowsError(try CodexZstdStream.decompress(Data("not zstd at all".utf8)))
        XCTAssertThrowsError(try CodexZstdStream.decompress(Data()))
    }

    func testStopsAtTheLimit() {
        XCTAssertThrowsError(try CodexZstdStream.decompress(CodexZstdFixture.big, limit: 200_000)) { error in
            guard case .tooLarge(let decoded)? = error as? CodexZstdError else { return XCTFail("\(error)") }
            XCTAssertGreaterThan(decoded, 200_000)
            XCTAssertLessThan(decoded, CodexZstdFixture.bigLength)
        }
    }
}

final class CodexSessionHeaderTests: XCTestCase {
    private func header(_ line: String) -> CodexSessionHeader? {
        CodexSessionHeader.parse(prefix: Data(line.utf8).prefix(CodexHostCommand.headerBytes))
    }

    func testReadsTheFieldsBeforeTheInstructions() throws {
        let parsed = try XCTUnwrap(header(CodexFixture.meta()))
        XCTAssertEqual(parsed.id, CodexFixture.threadID)
        XCTAssertEqual(parsed.cwd, CodexFixture.cwd, "提示词里写着的假 cwd 不算")
        XCTAssertEqual(parsed.originator, "codex-tui")
        XCTAssertEqual(parsed.source, .named("vscode"))
        XCTAssertEqual(parsed.threadSource, "user")
        XCTAssertNil(parsed.parentThreadID)
        XCTAssertTrue(parsed.isTopLevel)
        XCTAssertTrue(parsed.isFromCommandLine)
        XCTAssertNil(header(CodexFixture.user("hi")), "不是 session_meta")
        XCTAssertNil(header("{\"timestamp\":\"x\",\"type\":\"session_meta\",\"payload\":{\"cw"), "连 ID 都没有")
    }

    /// 哪些列：命令行起的顶层会话。桌面版、VS Code、`codex exec` 是顶层但不列；子代理、审查不是顶层。
    func testOriginRules() throws {
        func make(originator: String = "codex-tui", source: String = #""vscode""#, threadSource: String? = "user",
                  parent: String? = nil) throws -> CodexSessionHeader {
            try XCTUnwrap(header(CodexFixture.meta(originator: originator, source: source, threadSource: threadSource, parent: parent)))
        }
        XCTAssertTrue(try make(originator: "codex_cli_rs", source: #""cli""#).isFromCommandLine)
        XCTAssertTrue(try make(threadSource: nil).isFromCommandLine, "老版本没有 thread_source")
        for originator in ["Codex Desktop", "codex_vscode", "codex_exec", "codex_work_desktop"] {
            let made = try make(originator: originator)
            XCTAssertTrue(made.isTopLevel, originator)
            XCTAssertFalse(made.isFromCommandLine, originator)
        }
        let parent = "019a0000-0000-7000-8000-00000000abcd"
        let spawned = try make(source: CodexFixture.spawnSource(parent: parent, path: "/root/fix_tests"),
                               threadSource: "subagent", parent: parent)
        XCTAssertEqual(spawned.source, .threadSpawn)
        XCTAssertEqual(spawned.parentThreadID, parent)
        XCTAssertEqual(spawned.agentID, "fix_tests")
        XCTAssertFalse(spawned.isTopLevel)
        let guardian = try make(source: #"{"subagent":{"other":"guardian"}}"#, threadSource: "guardian_review")
        XCTAssertEqual(guardian.source, .otherSubagent)
        XCTAssertFalse(guardian.isTopLevel)
        XCTAssertFalse(try make(threadSource: "memory_consolidation").isTopLevel)
        // 没有 originator 的很老的记录：看 source。
        let old = try XCTUnwrap(header(#"{"timestamp":"t","type":"session_meta","payload":{"id":"\#(CodexFixture.threadID)","cwd":"/a","source":"cli"}}"#))
        XCTAssertTrue(old.isFromCommandLine)
    }

    /// 主机上那条命令回的一行：值是 JSON 引号里的原样（转义没解）。
    func testParsesHostOutputLines() {
        let lines: [Substring] = [
            "1\t\(CodexFixture.threadID)\t/home/u/it\\\"s \\u4e2d\tcodex-tui\tvscode\tuser\t\t\t",
            "2 ?", "3 -", "garbage", "uterm-codex:nozstd",
            "4\tid-4\t/x\tCodex Desktop\t{thread_spawn\tsubagent\tparent-1\t/root/a\t",
        ]
        let parsed = CodexHostCommand.headerLines(lines)
        XCTAssertEqual(parsed.map(\.index), [1, 2, 3, 4])
        XCTAssertEqual(parsed[0].header?.cwd, "/home/u/it\"s 中")
        XCTAssertEqual(parsed[0].header?.source, .named("vscode"))
        XCTAssertNil(parsed[0].header?.parentThreadID)
        XCTAssertTrue(parsed[1].missingZstd)
        XCTAssertNil(parsed[2].header)
        XCTAssertFalse(parsed[2].missingZstd)
        XCTAssertEqual(parsed[3].header?.source, .threadSpawn)
        XCTAssertEqual(parsed[3].header?.agentID, "a")
    }

    func testSessionIndexLastNameWins() {
        let data = Data("""
            {"id":"a","thread_name":"旧名字","updated_at":"2026-11-01T00:00:00Z"}
            {"id":"b","thread_name":"另一个\\n两行","updated_at":"2026-11-01T00:00:00Z"}
            {"id":"a","thread_name":"新名字","updated_at":"2026-11-02T00:00:00Z"}
            not json

            """.utf8)
        XCTAssertEqual(CodexSessionIndex.names(from: data, dropsLeadingPartial: false), ["a": "新名字", "b": "另一个 两行"])
        // 从中间读的：第一段是半行，丢掉。
        let cut = data.dropFirst(10)
        XCTAssertEqual(CodexSessionIndex.names(from: Data(cut), dropsLeadingPartial: true)["a"], "新名字")
    }
}

final class CodexTranscriptParserTests: XCTestCase {
    private func kinds(_ line: String, minimumOrdinal: Int? = nil) -> [AgentTranscriptItem.Kind] {
        let bytes = Data(line.utf8)
        return CodexTranscriptParser.items(from: .init(offset: 10, length: bytes.count, bytes: bytes, isTruncated: false),
                                           minimumOrdinal: minimumOrdinal).map(\.kind)
    }

    func testUserTextWithoutInjectedBlocks() {
        XCTAssertEqual(kinds(CodexFixture.user("修一下 bug")), [.userText("修一下 bug")])
        XCTAssertEqual(kinds(CodexFixture.injected), [], "AGENTS.md 与环境说明不显示")
        XCTAssertEqual(kinds(CodexFixture.message(role: "user", blocks: [
            CodexFixture.inputText("<image name=[Image #1]>"), #"{"type":"input_image","image_url":"data:image/png;base64,AAAA"}"#,
            CodexFixture.inputText("</image>"), CodexFixture.inputText("看看这张图"),
        ])), [.image, .userText("看看这张图")])
        XCTAssertEqual(kinds(CodexFixture.user("<turn_aborted>\nThe user interrupted the previous turn.\n</turn_aborted>")),
                       [.notice("The user interrupted the previous turn.")])
        XCTAssertEqual(kinds(CodexFixture.user("<skill>\n<name>x</name>\n</skill>")), [])
        // 标签开头但不是整块包着的，是你自己写的字。
        XCTAssertEqual(kinds(CodexFixture.user("<div> 这个标签怎么不闭合")), [.userText("<div> 这个标签怎么不闭合")])
        XCTAssertEqual(kinds(CodexFixture.developer("系统提示")), [])
        XCTAssertEqual(kinds(CodexFixture.eventUserMessage("重复的一句")), [], "event_msg 是给界面的重复记录")
    }

    func testAssistantReasoningCompaction() {
        XCTAssertEqual(kinds(CodexFixture.assistant("好的")), [.assistantText("好的")])
        XCTAssertEqual(kinds(CodexFixture.reasoning("**想一想**")), [.thinking(AgentClippedText("**想一想**", limit: 100))])
        XCTAssertEqual(kinds(CodexFixture.line("response_item", #"{"type":"reasoning","summary":[],"content":null,"encrypted_content":"x"}"#)), [])
        XCTAssertEqual(kinds(CodexFixture.compacted("之前做了 A 和 B")), [.compactSummary(AgentClippedText("之前做了 A 和 B", limit: 100))])
        XCTAssertEqual(kinds(CodexFixture.line("response_item", #"{"type":"compaction","encrypted_content":"x"}"#)), [])
        XCTAssertEqual(kinds(CodexFixture.line("response_item", #"{"type":"agent_message","author":"a","recipient":"b","content":[{"type":"input_text","text":"子任务\n做完了"}]}"#)),
                       [.notice("子任务 做完了")])
    }

    func testToolCallsAndResults() throws {
        let items = [
            CodexFixture.functionCall("exec_command", arguments: ["cmd": "rg login", "workdir": "/w"], callID: "c1"),
            CodexFixture.functionOutput(callID: "c1", output: "hit\n"),
            CodexFixture.functionCall("shell", arguments: ["command": ["bash", "-lc", "ls -la"]], callID: "c2"),
            CodexFixture.functionOutput(callID: "c2", output: #"{"output":"no such file","metadata":{"exit_code":1,"duration_seconds":0.1}}"#),
            CodexFixture.customCall("apply_patch", input: "*** Begin Patch\n*** Update File: a.swift\n*** Add File: b.swift\n*** End Patch", callID: "c3"),
            CodexFixture.customOutput(callID: "c3", text: "Success"),
            CodexFixture.line("response_item", #"{"type":"local_shell_call","call_id":"c4","status":"completed","action":{"type":"exec","command":["git","status"]}}"#),
            CodexFixture.line("response_item", #"{"type":"web_search_call","status":"completed","action":{"type":"search","query":"swift zstd"}}"#),
        ].enumerated().flatMap { index, line -> [AgentTranscriptItem] in
            CodexTranscriptParser.items(fromJSON: Data(line.utf8), idPrefix: String(index))
        }
        let assembled = AgentTranscriptAssembler.attachResults(items)
        let calls = assembled.compactMap { item -> AgentToolCall? in
            if case .toolCall(let call) = item.kind { return call } else { return nil }
        }
        XCTAssertEqual(calls.map(\.name), ["exec_command", "shell", "apply_patch", "shell", "web_search"])
        XCTAssertEqual(calls.map(\.summary), ["rg login", "ls -la", "a.swift, b.swift", "git status", "swift zstd"])
        XCTAssertEqual(calls[0].result?.content.text, "hit\n")
        XCTAssertEqual(calls[1].result?.content.text, "no such file")
        XCTAssertEqual(calls[1].result?.isError, true, "退出码 1")
        XCTAssertEqual(calls[2].result?.content.text, "Success")
        XCTAssertNil(calls[3].result)
    }

    func testSpawnAgentCarriesTheTaskName() throws {
        let call = CodexTranscriptParser.items(fromJSON: Data(CodexFixture.functionCall(
            "spawn_agent", arguments: ["task_name": "fix_tests", "message": "把测试修好"], callID: "s1", namespace: "collaboration").utf8),
            idPrefix: "1")
        guard case .toolCall(let made)? = call.first?.kind else { return XCTFail() }
        XCTAssertEqual(made.spawn?.description, "fix_tests")
        let result = CodexTranscriptParser.items(fromJSON: Data(CodexFixture.functionOutput(
            callID: "s1", output: #"{"task_name":"fix_tests"}"#).utf8), idPrefix: "2")
        guard case .toolResult(let output)? = result.first?.kind else { return XCTFail() }
        XCTAssertEqual(output.spawnedAgentID, "fix_tests")
    }

    func testBadLinesOversizedAndOrdinalFloor() {
        XCTAssertEqual(kinds("{not json"), [])
        XCTAssertEqual(kinds(#"{"type":"response_item","payload":"x"}"#), [])
        XCTAssertEqual(kinds(CodexFixture.meta()), [])
        XCTAssertEqual(kinds(CodexFixture.turnContext(cwd: "/a")), [])
        let head = Data(CodexFixture.user("很长", ordinal: 7).utf8.prefix(200))
        XCTAssertEqual(CodexTranscriptParser.items(from: .init(offset: 0, length: 9_000_000, bytes: head, isTruncated: true)).map(\.kind),
                       [.oversized(bytes: 9_000_000)])
        XCTAssertEqual(CodexTranscriptParser.items(from: .init(offset: 0, length: 9_000_000, bytes: head, isTruncated: true),
                                                   minimumOrdinal: 8), [], "抄进来的父会话上下文")
        XCTAssertEqual(kinds(CodexFixture.user("抄进来的", ordinal: 3), minimumOrdinal: 5), [])
        XCTAssertEqual(kinds(CodexFixture.user("自己的", ordinal: 5), minimumOrdinal: 5), [.userText("自己的")])
        // 条目 ID 是行偏移 + 序号，和 Claude 的一样。
        let items = CodexTranscriptParser.items(from: .init(offset: 42, length: 1, bytes: Data(CodexFixture.user("a").utf8), isTruncated: false))
        XCTAssertEqual(items.map(\.id), ["42.0"])
        XCTAssertNotNil(items.first?.timestamp)
    }

    func testSearchableTextMatchesWhatTheMatcherSees() {
        let items = CodexTranscriptParser.items(fromJSON: Data(CodexFixture.user("Find the NEEDLE here").utf8), idPrefix: "0")
        let query = try! AgentHistorySearchQuery.validate("needle").get()
        XCTAssertEqual(AgentHistorySearchMatcher.firstHit(in: items, query: query)?.snippet.match, "NEEDLE")
    }
}
