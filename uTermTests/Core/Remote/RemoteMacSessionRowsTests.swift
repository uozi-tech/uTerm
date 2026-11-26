import XCTest
@testable import uTerm

/// 那台 Mac 的面板「Mac 上的终端」：Mac 的 Code 标签页里的会话收成一行 Code，排在它在 Mac 上的位置（`RemoteMacSessionRow`）。
final class RemoteMacSessionRowsTests: XCTestCase {
    private let ids = (0..<6).map { _ in UUID() }

    private func session(_ index: Int) -> RemoteSessionInfo {
        RemoteSessionInfo(id: ids[index], serverID: RemoteConstants.localShellServerID, serverName: "本机",
                          title: "zsh \(index)", windowKind: "terminal", order: index)
    }

    private func run(_ index: Int, tool: String = "claude", ended: Bool = false) -> RemoteCodeTabInfo.Run {
        RemoteCodeTabInfo.Run(session: ids[index], tool: tool, directory: "/w", startedAt: Date(timeIntervalSince1970: 0),
                              endedAt: ended ? Date(timeIntervalSince1970: 1) : nil)
    }

    private func codeTab(_ runs: [RemoteCodeTabInfo.Run], slot: Int?, selected: Int? = nil) -> RemoteCodeTabInfo {
        RemoteCodeTabInfo(id: UUID(), serverID: RemoteConstants.localShellServerID, serverName: "本机", slot: slot,
                          runs: runs, selectedRun: selected.map { ids[$0] })
    }

    func test_code_sessions_collapse_into_one_row_at_its_slot() {
        // Mac 上：zsh0、Code（会话 2、3）、zsh1、zsh4。会话列表按 Mac 的顺序，Code 里的会话也在里面。
        let sessions = [0, 2, 3, 1, 4].map(session)
        let tab = codeTab([run(2), run(3)], slot: 1)
        let rows = RemoteMacSessionRow.rows(sessions: sessions, codeTabs: [tab])
        XCTAssertEqual(rows.map(\.id), [ids[0], tab.id, ids[1], ids[4]], "一行 Code，排在第一个普通终端之后")
        guard case .codeTab(_, let owned) = rows[1] else { return XCTFail("第二行不是 Code") }
        XCTAssertEqual(owned.map(\.id), [ids[2], ids[3]])
    }

    func test_old_mac_or_no_code_tab_lists_every_session() {
        let sessions = [0, 1].map(session)
        XCTAssertEqual(RemoteMacSessionRow.rows(sessions: sessions, codeTabs: nil).map(\.id), [ids[0], ids[1]])
    }

    func test_unknown_tools_stay_separate_and_missing_slot_goes_last() {
        let sessions = [0, 1, 2].map(session)
        let tab = codeTab([run(1), run(2, tool: "future-tool")], slot: nil)
        let rows = RemoteMacSessionRow.rows(sessions: sessions, codeTabs: [tab])
        XCTAssertEqual(rows.map(\.id), [ids[0], ids[2], tab.id], "认不出的工具照旧各一行（接管后它也是终端标签页）")
    }

    func test_empty_code_tab_still_has_a_row_without_focus() {
        let tab = codeTab([], slot: 5)
        let rows = RemoteMacSessionRow.rows(sessions: [session(0)], codeTabs: [tab])
        XCTAssertEqual(rows.map(\.id), [ids[0], tab.id], "位置超出范围就排在最后")
        XCTAssertNil(rows[1].focus)
    }

    func test_focus_prefers_the_macs_selection_then_a_running_session() {
        let sessions = [1, 2, 3].map(session)
        XCTAssertEqual(RemoteMacSessionRow.rows(sessions: sessions, codeTabs: [codeTab([run(1), run(2)], slot: 0, selected: 2)])
            .first?.focus, ids[2], "Mac 右边看着的那个")
        XCTAssertEqual(RemoteMacSessionRow.rows(sessions: sessions, codeTabs: [codeTab([run(1, ended: true), run(3)], slot: 0)])
            .first?.focus, ids[3], "没在看哪个：第一个还在跑的")
        XCTAssertEqual(RemoteMacSessionRow.rows(sessions: sessions, codeTabs: [codeTab([run(1, ended: true)], slot: 0)])
            .first?.focus, ids[1], "都结束了：第一个")
        XCTAssertEqual(RemoteMacSessionRow.rows(sessions: [session(0)], codeTabs: [codeTab([run(1)], slot: 0, selected: 1)])
            .first?.focus, nil, "会话列表里还没有的不落过去")
    }

    func test_ssh_host_code_tabs_get_their_own_rows() {
        // Mac 上：zsh0、本机 Code（会话 1）、ssh 终端 2、srv 主机的 Code（会话 3、4）。
        let host = UUID()
        let sessions = [0, 1, 2, 3, 4].map(session)
        let local = codeTab([run(1)], slot: 1)
        var ssh = codeTab([run(3), run(4)], slot: 2)
        ssh.serverID = host
        ssh.serverName = "srv"
        var duplicate = codeTab([run(2)], slot: 0)
        duplicate.serverID = host
        let rows = RemoteMacSessionRow.rows(sessions: sessions, codeTabs: [local, ssh, duplicate])
        XCTAssertEqual(rows.map(\.id), [ids[0], local.id, ids[2], ssh.id], "每台主机一行；同一台主机的第二个不收")
        guard case .codeTab(let info, let owned) = rows[3] else { return XCTFail("最后一行不是 srv 的 Code") }
        XCTAssertEqual(info.serverName, "srv")
        XCTAssertEqual(owned.map(\.id), [ids[3], ids[4]])
    }
}
