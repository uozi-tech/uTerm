import XCTest
@testable import uTerm

/// Claude Code 的列表读索引：`history.jsonl` 只读新长出来的那一段、没变的项目目录不再列、记录变长了只读新长出来的那一段。
/// 结果要和原来的读法（`readsIndex: false`）一样。内容全是编的。
final class ClaudeHistoryIndexTests: XCTestCase {
    private typealias C = ClaudeFixture
    private let home = "/home/user"
    private var root: String { home + "/.claude/projects" }
    private var historyPath: String { home + "/.claude/history.jsonl" }

    // MARK: history.jsonl

    private func historyLine(_ session: String, project: String = "/home/user/projects/demo") -> String {
        #"{"display":"问一句","pastedContents":{},"timestamp":1795698568982,"project":\#(C.json(project)),"sessionId":"\#(session)"}"#
    }

    func testHistoryLogReadsOnlyWhatGrewAndKeepsTheHalfWrittenLine() {
        var log = ClaudeHistoryLog()
        let first = Data((historyLine("s-1") + "\n" + historyLine("s-2") + "\n").utf8)
        guard case .rebase(let offset, let length) = log.plan(size: UInt64(first.count)) else { return XCTFail("没有基线先建") }
        log.rebase(first.subdata(in: Int(offset)..<Int(offset) + length), from: offset)
        XCTAssertEqual(log.plan(size: UInt64(first.count)), .unchanged)

        // 长了一行半：读回来的从上次末尾前面那几个字节起。
        let half = historyLine("s-4", project: "/srv/other app")
        let grown = first + Data((historyLine("s-3") + "\n" + half.prefix(20)).utf8)
        guard case .read(let start, let count) = log.plan(size: UInt64(grown.count)) else { return XCTFail("应该增量读") }
        XCTAssertLessThan(start, UInt64(first.count))
        XCTAssertEqual(UInt64(first.count) - start, UInt64(ClaudeReadPosition.anchorBytes))
        let touches = log.consume(grown.subdata(in: Int(start)..<Int(start) + count), from: start)
        XCTAssertEqual(touches, ClaudeHistoryLog.Touches(sessionIDs: ["s-3"], projects: ["-home-user-projects-demo"]))

        // 那半行写完了：下次读到它。
        let done = grown + Data((half.dropFirst(20) + "\n").utf8)
        guard case .read(let start2, let count2) = log.plan(size: UInt64(done.count)) else { return XCTFail() }
        let next = log.consume(done.subdata(in: Int(start2)..<Int(start2) + count2), from: start2)
        XCTAssertEqual(next, ClaudeHistoryLog.Touches(sessionIDs: ["s-4"], projects: ["-srv-other-app"]))
    }

    func testHistoryLogRebasesWhenReplacedOrShrunk() {
        var log = ClaudeHistoryLog()
        let first = Data((historyLine("s-1") + "\n").utf8)
        log.rebase(first, from: 0)
        // 变短了。
        guard case .rebase = log.plan(size: 3) else { return XCTFail("变短了要重建基线") }
        // 换成了一份更长的别的文件：开头那几个字节对不上。
        let other = Data((historyLine("x-9", project: "/elsewhere") + "\n" + historyLine("x-8") + "\n").utf8)
        guard case .read(let start, let count) = log.plan(size: UInt64(other.count)) else { return XCTFail() }
        XCTAssertNil(log.consume(other.subdata(in: Int(start)..<Int(start) + count), from: start))
        XCTAssertNil(log.position, "下次重建基线")
    }

    // MARK: 记录变长

    /// 一份 64 KB 以上的记录：开头一句话、一堆快照行、最后一句与标题。
    private func record(title: String, tail: [String] = []) -> [String] {
        var lines = [C.userText("开头", cwd: "/home/user/projects/demo")]
        for index in 0..<1200 { lines.append(C.noise(index)) }
        lines.append(C.userText("中间", uuid: "u-2", cwd: "/home/user/projects/demo/sub"))
        lines.append(C.aiTitle(title))
        return lines + tail
    }

    private func host(_ data: Data, mtime: Date = Date(timeIntervalSince1970: 1_000)) async -> MockSFTP {
        let project = "-home-user-projects-demo"
        let sftp = MockSFTP(tree: [
            root: [C.entry(project, directory: true, mtime: mtime)],
            "\(root)/\(project)": [C.entry("\(C.sessionID).jsonl", size: UInt64(data.count), mtime: mtime)],
        ])
        await sftp.setFile("\(root)/\(project)/\(C.sessionID).jsonl", data: data, mtime: mtime)
        return sftp
    }

    private func onlyFile(_ source: ClaudeHistorySource) async throws -> AgentHistorySessionFile {
        let projects = try await source.projects()
        let files = await source.allSessions(in: projects)
        return try XCTUnwrap(files.first)
    }

    /// 变长了只读新长出来的那一段，读出来的和原来的读法整份重读的一样。
    func testGrownRecordReadsOnlyTheNewBytesAndMatchesAFullRead() async throws {
        let before = C.file(record(title: "旧标题"))
        let sftp = await host(before)
        let source = ClaudeHistorySource(provider: sftp, home: home)
        let file = try await onlyFile(source)
        let first = try await source.metadata(for: file)
        XCTAssertEqual(first.title, "旧标题")

        let appended = [C.userText("后来又问", uuid: "u-3", cwd: "/home/user/projects/demo/other"),
                        C.assistant(C.textBlock("回答"), uuid: "a-3", cwd: "/home/user/projects/demo/other"), C.aiTitle("新标题"), C.noise(9_999)]
        let after = C.file(record(title: "旧标题", tail: appended))
        let later = Date(timeIntervalSince1970: 2_000)
        await sftp.setFile(file.path, data: after, mtime: later)
        let grown = AgentHistorySessionFile(sessionID: file.sessionID, project: file.project, path: file.path,
                                            size: UInt64(after.count), modifiedAt: later)
        await sftp.clearRangeReads()
        let second = try await source.metadata(for: grown)
        let reads = await sftp.rangeReads
        XCTAssertEqual(reads.count, 1)
        XCTAssertEqual(reads.first.map { UInt64($0.length) }, UInt64(after.count - before.count + ClaudeReadPosition.anchorBytes),
                       "只读新长出来的（连着前面几个核对用的字节）")

        let fresh = ClaudeHistorySource(provider: await host(after, mtime: later), home: home, readsIndex: false)
        let expected = try await fresh.metadata(for: try await onlyFile(fresh))
        XCTAssertEqual(second, expected)
        XCTAssertEqual(second.title, "新标题")
        XCTAssertEqual(second.lastDirectory, "/home/user/projects/demo/other")
    }

    /// 用户改过的名字不管多早都算数：后来 AI 又起了名字，照样显示改过的。
    func testCustomTitleSurvivesLaterAITitles() async throws {
        let before = C.file(record(title: "AI 起的", tail: [C.customTitle("我改的")]))
        let sftp = await host(before)
        let source = ClaudeHistorySource(provider: sftp, home: home)
        let file = try await onlyFile(source)
        _ = try await source.metadata(for: file)
        var lines = record(title: "AI 起的", tail: [C.customTitle("我改的")])
        for index in 0..<1200 { lines.append(C.noise(20_000 + index)) }
        lines.append(C.aiTitle("AI 后来又起的"))
        let after = C.file(lines)
        await sftp.setFile(file.path, data: after, mtime: Date(timeIntervalSince1970: 2_000))
        let grown = AgentHistorySessionFile(sessionID: file.sessionID, project: file.project, path: file.path,
                                            size: UInt64(after.count), modifiedAt: Date(timeIntervalSince1970: 2_000))
        let metadata = try await source.metadata(for: grown)
        XCTAssertEqual(metadata.title, "我改的")
    }

    /// 同一个路径换成了别的文件（更长、开头不一样）：对不上就整份重读，不把两份拼在一起。
    func testReplacedRecordIsReadAgainInFull() async throws {
        let before = C.file(record(title: "旧的"))
        let sftp = await host(before)
        let source = ClaudeHistorySource(provider: sftp, home: home)
        let file = try await onlyFile(source)
        _ = try await source.metadata(for: file)
        var lines = [C.userText("另一份", uuid: "x-1")]
        for index in 0..<2000 { lines.append(C.noise(50_000 + index)) }
        lines.append(C.aiTitle("换过的"))
        let other = C.file(lines)
        await sftp.setFile(file.path, data: other, mtime: Date(timeIntervalSince1970: 3_000))
        let replaced = AgentHistorySessionFile(sessionID: file.sessionID, project: file.project, path: file.path,
                                               size: UInt64(other.count), modifiedAt: Date(timeIntervalSince1970: 3_000))
        let metadata = try await source.metadata(for: replaced)
        let fresh = ClaudeHistorySource(provider: await host(other, mtime: Date(timeIntervalSince1970: 3_000)), home: home,
                                        readsIndex: false)
        let expected = try await fresh.metadata(for: try await onlyFile(fresh))
        XCTAssertEqual(metadata, expected)
    }

    // MARK: 没变的项目目录不再列

    private let demo = "-home-user-projects-demo"
    private let old = "-srv-old"
    private let older = "-srv-older"
    private let fresh = "11111111-1111-4111-8111-111111111111"
    private let stale = "22222222-2222-4222-8222-222222222222"
    private let ancient = "33333333-3333-4333-8333-333333333333"

    private func listingHost(now: Date, withHistory: Bool = true) async -> MockSFTP {
        let tree = listingTree(now: now, oldModified: now.addingTimeInterval(-7_200))
        let sftp = MockSFTP(tree: tree)
        if withHistory { await sftp.setFile(historyPath, data: Data((historyLine(fresh) + "\n").utf8), mtime: now) }
        for (project, session, age) in [(demo, fresh, 60.0), (old, stale, 7_200.0), (older, ancient, 10_800.0)] {
            await sftp.setFile("\(root)/\(project)/\(session).jsonl", data: C.file([C.userText("a")]),
                               mtime: now.addingTimeInterval(-age))
        }
        return sftp
    }

    private func listingTree(now: Date, oldModified: Date, staleSize: UInt64 = 10) -> [String: [RemoteEntry]] {
        [
            root: [C.entry(demo, directory: true, mtime: now), C.entry(old, directory: true, mtime: oldModified),
                   C.entry(older, directory: true, mtime: now.addingTimeInterval(-10_800))],
            "\(root)/\(demo)": [C.entry("\(fresh).jsonl", size: 10, mtime: now.addingTimeInterval(-60))],
            "\(root)/\(old)": [C.entry("\(stale).jsonl", size: staleSize, mtime: now.addingTimeInterval(-7_200 + (staleSize == 10 ? 0 : 7_100)))],
            "\(root)/\(older)": [C.entry("\(ancient).jsonl", size: 10, mtime: now.addingTimeInterval(-10_800))],
        ]
    }

    private func projectLists(_ sftp: MockSFTP) async -> Set<String> {
        Set(await sftp.listCalls.filter { $0.hasPrefix(root + "/") }.map { ($0 as NSString).lastPathComponent })
    }

    func testUnchangedProjectDirectoriesAreNotListedAgain() async throws {
        let now = Date()
        let sftp = await listingHost(now: now)
        let source = ClaudeHistorySource(provider: sftp, home: home)

        // 第一趟没有基线：全列。
        var projects = try await source.projects()
        var files = await source.allSessions(in: projects)
        XCTAssertEqual(files.count, 3)
        var lists = await projectLists(sftp)
        XCTAssertEqual(lists, [demo, old, older])

        // 什么都没变：只列最近半小时动过的那一个。
        await sftp.resetCallCounters()
        projects = try await source.projects()
        files = await source.allSessions(in: projects)
        XCTAssertEqual(files.count, 3)
        lists = await projectLists(sftp)
        XCTAssertEqual(lists, [demo])

        // 老项目里一份老会话又被继续了（追加不改目录的修改时间）：history.jsonl 里有它的新提问 → 那个项目重列。
        let resumedAt = now.addingTimeInterval(-100)
        await sftp.setTree(listingTree(now: now, oldModified: now.addingTimeInterval(-7_200), staleSize: 99))
        await sftp.setFile(historyPath, data: Data((historyLine(fresh) + "\n" + historyLine(stale, project: "/srv/old") + "\n").utf8),
                           mtime: resumedAt)
        await sftp.resetCallCounters()
        projects = try await source.projects()
        files = await source.allSessions(in: projects)
        lists = await projectLists(sftp)
        XCTAssertEqual(lists, [demo, old])
        XCTAssertEqual(files.first { $0.sessionID == stale }?.size, 99)

        // 和原来的读法列的一样。
        let full = ClaudeHistorySource(provider: sftp, home: home, readsIndex: false)
        let expected = await full.allSessions(in: try await full.projects())
        XCTAssertEqual(files.map(\.cacheKey), expected.map(\.cacheKey))

        // 有项目目录的修改时间变了（新建、删除了记录）：它重列。
        await sftp.setTree(listingTree(now: now, oldModified: now.addingTimeInterval(-7_000), staleSize: 99))
        await sftp.resetCallCounters()
        projects = try await source.projects()
        _ = await source.allSessions(in: projects)
        lists = await projectLists(sftp)
        XCTAssertTrue(lists.contains(old))
        XCTAssertFalse(lists.contains(older))
    }

    /// 没有 history.jsonl（老版本）：看不出老会话被继续了，每趟都全列（同原来）。
    func testWithoutHistoryLogEverythingIsListed() async throws {
        let now = Date()
        let sftp = await listingHost(now: now, withHistory: false)
        let source = ClaudeHistorySource(provider: sftp, home: home)
        _ = await source.allSessions(in: try await source.projects())
        await sftp.resetCallCounters()
        _ = await source.allSessions(in: try await source.projects())
        let lists = await projectLists(sftp)
        XCTAssertEqual(lists, [demo, old, older])
    }
}
