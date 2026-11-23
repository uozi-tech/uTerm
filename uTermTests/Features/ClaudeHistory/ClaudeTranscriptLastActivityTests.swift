import XCTest
@testable import uTerm

/// 顶栏的「最后活动」：已加载内容里最新那条的时间。实时跟随接上新的就变新，往前翻旧页不改旧，从搜索命中处打开时
/// 是已加载部分里最新那条的（不是文件末尾的）。手写的假记录，时钟是假的。
@MainActor
final class ClaudeTranscriptLastActivityTests: XCTestCase {
    private let path = "/home/user/.claude/projects/-p/0b0e5f3a-1c2d-4e5f-8a9b-0c1d2e3f4a5b.jsonl"
    private static let fixedStamp = "2026-11-20T10:00:00.000Z"

    /// `ClaudeFixture` 的行都是同一个时间戳：换成 `minutes` 分钟后的那一刻。
    private func at(_ minutes: Int, _ line: String) -> String {
        line.replacingOccurrences(of: Self.fixedStamp, with: Self.stamp(minutes))
    }

    private static let base = ClaudeTimestamp.parse(fixedStamp)!
    private static func date(_ minutes: Int) -> Date { base.addingTimeInterval(TimeInterval(minutes * 60)) }
    private static func stamp(_ minutes: Int) -> String {
        date(minutes).formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    private func turns(_ range: ClosedRange<Int>) -> [String] {
        range.flatMap { turn in
            [at(turn, ClaudeFixture.userText("问题 \(turn)", uuid: "u-\(turn)")),
             at(turn, ClaudeFixture.assistant(ClaudeFixture.textBlock("回答 \(turn)"), uuid: "a-\(turn)"))]
        }
    }

    private func timing(date: Date) -> AgentTranscriptFollowTiming {
        var timing = FollowClock().timing()
        timing.date = { date }
        return timing
    }

    private func sftp(_ lines: [String]) async -> MockSFTP {
        let sftp = MockSFTP()
        await sftp.setFile(path, data: ClaudeFixture.file(lines), mtime: Date())
        return sftp
    }

    private func file(size: Int) -> AgentHistorySessionFile {
        let project = AgentHistoryProject(id: "-p", path: "/home/user/.claude/projects/-p", modifiedAt: nil)
        return AgentHistorySessionFile(sessionID: "0b0e5f3a-1c2d-4e5f-8a9b-0c1d2e3f4a5b", project: project, path: path,
                                       size: UInt64(size), modifiedAt: Self.date(-600))
    }

    func testFollowMovesItForwardAndOlderPagesNeverMoveItBack() async throws {
        let sftp = await sftp(turns(1...60))
        let now = Self.date(1_000)
        let transcript = AgentTranscriptModel(
            file: file(size: 0),
            pager: ClaudeTranscriptPager(provider: sftp, path: path, chunkBytes: 2048, pageItems: 6),
            followTiming: timing(date: now))
        await transcript.loadEarlier()
        XCTAssertFalse(transcript.reachedStart)
        XCTAssertEqual(transcript.lastActivity, Self.date(60), "第一页里最新那条")

        // 往前翻旧页：不改旧。
        await transcript.loadEarlier()
        await transcript.loadEarlier()
        XCTAssertEqual(transcript.lastActivity, Self.date(60))

        // 跟随接上一条带新时间戳的。
        var data = try await sftp.readRange(path, offset: 0, length: Int.max / 2)
        data.append(Data((at(75, ClaudeFixture.userText("新的问题", uuid: "u-new")) + "\n").utf8))
        await sftp.setFile(path, data: data, mtime: Date())
        await transcript.followOnce()
        XCTAssertEqual(transcript.items.last?.kind, .userText("新的问题"))
        XCTAssertEqual(transcript.lastActivity, Self.date(75))

        // 接上一条没带时间戳的：记成读到它的那一刻。
        data.append(Data((ClaudeFixture.userText("没有时间戳", uuid: "u-bare")
            .replacingOccurrences(of: #""timestamp":"\#(Self.fixedStamp)","#, with: "") + "\n").utf8))
        await sftp.setFile(path, data: data, mtime: Date())
        await transcript.followOnce()
        XCTAssertEqual(transcript.items.last?.kind, .userText("没有时间戳"))
        XCTAssertEqual(transcript.lastActivity, now)

        // 顶栏的字跟着它走。
        XCTAssertEqual(AgentHistoryText.transcriptDetail(transcript, metadata: nil).split(separator: "·").last?
            .trimmingCharacters(in: .whitespaces), AgentHistoryText.relative(now))
    }

    func testOpeningAtAHitUsesTheNewestLoadedItemNotTheFileEnd() async throws {
        let lines = turns(1...40)
        let sftp = await sftp(lines)
        var offset = 0
        var offsets: [Int] = []
        for line in lines {
            offsets.append(offset)
            offset += line.utf8.count + 1
        }
        let hit = 20   // 「问题 11」
        let anchor = AgentTranscriptAnchor(lineOffset: UInt64(offsets[hit]), lineLength: offsets[hit + 1] - offsets[hit] - 1)
        let transcript = AgentTranscriptModel(
            file: file(size: offset),
            pager: ClaudeTranscriptPager(provider: sftp, path: path, anchor: anchor, chunkBytes: 2048, pageItems: 6),
            followTiming: timing(date: Self.date(5_000)), opensAt: "\(offsets[hit]).0")
        await transcript.loadEarlier()
        XCTAssertEqual(transcript.items.last?.kind, .userText("问题 11"))
        XCTAssertEqual(transcript.lastActivity, Self.date(11), "命中那条的时间，不是文件末尾（40）的")
        // 跟随在读到末尾之前不干活，也不会把时间改成此刻。
        await transcript.followOnce()
        XCTAssertEqual(transcript.lastActivity, Self.date(11))
        // 往后读一页：跟着变新。
        await transcript.loadLater()
        XCTAssertGreaterThan(try XCTUnwrap(transcript.lastActivity), Self.date(11))
    }

    // MARK: - 列表那一行

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<300 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// 列表里的时间是列出来那一刻的文件修改时间；看着的会话接上了新内容，那一行跟着顶栏一起变新，切到别的会话后
    /// 还记着，重新列一次才回到列表自己的时间。
    func testListRowFollowsTheOpenTranscriptAndRemembersAfterSwitching() async throws {
        let root = "/home/user/.claude/projects"
        let project = "-home-user-projects-demo"
        let other = "7c1d2e3f-4a5b-4c6d-8e9f-0a1b2c3d4e5f"
        let pathA = "\(root)/\(project)/\(ClaudeFixture.sessionID).jsonl"
        let pathB = "\(root)/\(project)/\(other).jsonl"
        // 列表里记的修改时间是 5 天前，记录里的条目更早；新写进来的那条是一分钟前。
        let listed = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 5 * 86_400).rounded(.down))
        let fresh = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 60).rounded(.down))
        func stamped(_ date: Date, _ line: String) -> String {
            line.replacingOccurrences(of: Self.fixedStamp,
                                      with: date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
        }
        let old = listed.addingTimeInterval(-3_600)
        let dataA = ClaudeFixture.file([stamped(old, ClaudeFixture.userText("登录接口偶发 500", uuid: "u-1")),
                                        stamped(old, ClaudeFixture.assistant(ClaudeFixture.textBlock("我看看"), uuid: "a-1"))])
        let dataB = ClaudeFixture.file([stamped(old, ClaudeFixture.userText("给订单接口加分页", uuid: "u-2"))])
        let sftp = MockSFTP()
        await sftp.setFile(pathA, data: dataA, mtime: listed)
        await sftp.setFile(pathB, data: dataB, mtime: listed)
        await sftp.setTree([
            root: [ClaudeFixture.entry(project, directory: true)],
            "\(root)/\(project)": [
                ClaudeFixture.entry("\(ClaudeFixture.sessionID).jsonl", size: UInt64(dataA.count), mtime: listed),
                ClaudeFixture.entry("\(other).jsonl", size: UInt64(dataB.count), mtime: listed.addingTimeInterval(-60)),
            ],
        ])
        let model = AgentHistoryModel(source: ClaudeHistorySource(provider: sftp), preferredDirectory: ClaudeFixture.cwd,
                                      followTiming: FollowClock().timing())
        await model.start()
        await waitUntil { !model.hasMore }
        let fileA = try XCTUnwrap(model.files.first { $0.path == pathA })
        let fileB = try XCTUnwrap(model.files.first { $0.path == pathB })

        model.select(fileA)
        let transcript = try XCTUnwrap(model.transcript)
        await waitUntil { transcript.reachedStart }
        XCTAssertNil(model.liveActivity(of: fileA), "刚打开：读到的不比列表里的时间新，那一行照旧")
        XCTAssertNil(model.liveActivity(of: fileB))

        var grown = dataA
        grown.append(Data((stamped(fresh, ClaudeFixture.userText("压测还有超时吗？", uuid: "u-3")) + "\n").utf8))
        await sftp.setFile(pathA, data: grown, mtime: Date())
        await transcript.followOnce()
        XCTAssertEqual(transcript.lastActivity, fresh)
        XCTAssertEqual(model.liveActivity(of: fileA), fresh, "跟着顶栏一起变新")
        XCTAssertNil(model.liveActivity(of: fileB), "别的会话不受影响")
        let metadata = model.metadata[pathA]
        let row = AgentHistoryText.sessionSubtitle(fileA, metadata: metadata, showsProject: false,
                                                   activity: model.liveActivity(of: fileA))
        XCTAssertTrue(row.hasPrefix(AgentHistoryText.relative(fresh) + " · "), row)
        XCTAssertTrue(AgentHistoryText.sessionSubtitle(fileA, metadata: metadata, showsProject: false)
            .hasPrefix(AgentHistoryText.relative(listed) + " · "), "没有更新的时间就用列表里的")
        XCTAssertTrue(AgentHistoryText.sessionSubtitle(fileA, metadata: metadata, showsProject: false, activity: old)
            .hasPrefix(AgentHistoryText.relative(listed) + " · "), "给的时间更旧也不会把它改旧")

        // 切到别的会话：那一行还记着。
        model.select(fileB)
        XCTAssertEqual(model.liveActivity(of: fileA), fresh)
        XCTAssertNil(model.liveActivity(of: fileB))

        // 重新列一次：列表里的修改时间是新的了，记的那份清掉。
        await model.reload()
        await waitUntil { !model.hasMore }
        XCTAssertNil(model.liveActivity(of: fileA))
    }

    func testSubagentHeaderUsesItToo() {
        let link = AgentSubagentLink(file: AgentSubagentFile(agentID: "a1", path: "/x/agent-a1.jsonl", size: 10,
                                                             modifiedAt: Self.date(-10_000), hasInfo: false),
                                     agentType: "Explore", description: "查慢查询")
        XCTAssertTrue(AgentHistoryText.subagentDetail(link, lastActivity: Self.date(0))
            .hasSuffix(" · " + AgentHistoryText.relative(Self.date(0))))
        XCTAssertTrue(AgentHistoryText.subagentDetail(link).hasSuffix(" · " + AgentHistoryText.relative(Self.date(-10_000))),
                      "没有就退回记录文件的修改时间")
    }
}
