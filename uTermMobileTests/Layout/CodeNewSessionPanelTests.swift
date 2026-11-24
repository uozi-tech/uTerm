import XCTest
@testable import uTermMobile

/// Code 标签页的「＋」：弹新会话面板（不直接起）、候选目录与 Mac 同一份规则（当前目录、记录的项目、主目录）、
/// 选的目录写回标签页（随归档存着）、「输入路径…」经这个标签页的文件通道核对。文件读的是手写的假树，不建真实连接。
@MainActor
final class CodeNewSessionPanelTests: XCTestCase {

    private func host(_ name: String = "prod-web-01") -> ServerProfile {
        let host = ServerProfile()
        host.name = name
        return host
    }

    private func openTab(directory: String? = MobileClaudeFixture.directory) async throws -> ClaudeHistoryTab {
        let tab = MobileFakeClaudeHistory.tab(host: host(), tree: MobileClaudeFixture.standard(), directory: directory)
        tab.start()
        let settled = await MobileFakeClaudeHistory.settle(tab)
        XCTAssertTrue(settled)
        let home = await MobileFakeTerminal.waitUntil { tab.connection.homeDirectory != nil }
        XCTAssertTrue(home, "连上之后问到主目录")
        return tab
    }

    func testPlusPresentsThePanelWithTheSharedCandidates() async throws {
        let tab = try await openTab()
        XCTAssertNil(tab.newSessionDraft)
        tab.presentNewSession()
        let draft = try XCTUnwrap(tab.newSessionDraft, "「＋」弹面板，不直接起")
        XCTAssertTrue(tab.runs.runs.isEmpty)
        XCTAssertEqual(draft.directory, MobileClaudeFixture.directory, "默认选着这个标签页的目录")
        XCTAssertEqual(draft.choices, [MobileClaudeFixture.directory, MobileClaudeFixture.home],
                       "当前目录（和记录的项目同一个，只出一次）、主目录")
        XCTAssertEqual(draft.display(MobileClaudeFixture.directory), "~/projects/shop-api")
        let history = try XCTUnwrap(tab.connection.history)
        XCTAssertEqual(history.newSessionTools(directory: draft.directory), [.claude], "只有一种：面板里不出工具选择")
        tab.close()
    }

    func testTabWithoutADirectoryPicksOneAndItIsWrittenBack() async throws {
        let tab = try await openTab(directory: nil)
        XCTAssertNil(tab.directory)
        tab.presentNewSession()
        let draft = try XCTUnwrap(tab.newSessionDraft)
        XCTAssertNil(draft.directory, "不知道目录：先选一个，开始按钮灰着")
        XCTAssertEqual(draft.choices, [MobileClaudeFixture.directory, MobileClaudeFixture.home], "记录的项目、主目录")
        let history = try XCTUnwrap(tab.connection.history)
        XCTAssertEqual(history.newSessionTools(directory: nil), [])

        draft.directory = MobileClaudeFixture.home
        XCTAssertEqual(history.newSessionTools(directory: draft.directory), [.claude])
        XCTAssertEqual(history.newSessionCommand(tool: .claude, directory: MobileClaudeFixture.home),
                       "cd -- '\(MobileClaudeFixture.home)' && claude")
        tab.chooseNewSessionDirectory(MobileClaudeFixture.home + "/")
        XCTAssertEqual(tab.directory, MobileClaudeFixture.home, "写回标签页（规整过），下次「＋」默认它")
        tab.newSessionDraft = nil
        tab.presentNewSession()
        XCTAssertEqual(tab.newSessionDraft?.choices.first, MobileClaudeFixture.home, "选过的排第一")
        tab.close()
    }

    func testTypedPathIsCheckedThroughTheFileChannel() async throws {
        let tab = try await openTab()
        let entry = AgentHistoryPathEntry(text: "~/nope")
        let missing = await entry.submit(using: tab.connection)
        XCTAssertNil(missing, "不存在：不关、说一句")
        XCTAssertEqual(entry.problem, .missing(MobileClaudeFixture.home + "/nope"))

        entry.text = "~/.claude/projects/" + MobileClaudeFixture.project + "/" + MobileClaudeFixture.sessionID(1) + ".jsonl"
        let file = await entry.submit(using: tab.connection)
        XCTAssertNil(file)
        if case .notDirectory = entry.problem {} else { XCTFail("是文件不是目录：\(String(describing: entry.problem))") }

        entry.text = "~/.claude"
        let ok = await entry.submit(using: tab.connection)
        XCTAssertEqual(ok, MobileClaudeFixture.home + "/.claude", "~ 照主机上的主目录展开")
        XCTAssertNil(entry.problem)

        entry.text = "relative/dir"
        let relative = await entry.submit(using: tab.connection)
        XCTAssertNil(relative)
        XCTAssertEqual(entry.problem, .notAbsolute)
        tab.close()
    }

    func testPairedMacThatCannotOpenShellsHasNoPlus() {
        let mac = RemoteMacClient(macName: "老 Mac", endpoint: .hostPort(host: "127.0.0.1", port: 1),
                                  identity: RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage()))
        let tab = ClaudeHistoryTab(pairedMac: mac)
        XCTAssertFalse(tab.canResume, "还没握手（不知道能不能新建本机终端）：不出「＋」，照旧")
        mac.disconnect()
    }
}
