import Network
import SwiftData
import SwiftUI
import UIKit
import XCTest
@testable import uTermMobile

/// 手机终端里程序（Claude Code、Codex）的状态：OSC 7501 / 133 的规则与 mac 同一份（`ProgramStatusTracker`），
/// 同一串字节在两端得到同样的标签状态（对照 mac 的 `TerminalProgramStatusTests`）。
@MainActor
final class MobileProgramStatusTests: XCTestCase {

    private func host() throws -> (ModelContainer, ServerProfile, HostKeyChallengeRelay) {
        let c = try MobileFixtures.modelContainer(seed: .smoke)
        let h = try XCTUnwrap(MobileFixtures.firstServer(in: c))
        return (c, h, HostKeyChallengeRelay())
    }

    /// 像后端输出一样喂给这条会话的终端。影子终端当场解析，主线程上喂的事件同步到达控制器。
    private func osc(_ controller: MobileTerminalController, _ code: Int, _ payload: String) {
        controller.terminal.feed(Data("\u{1b}]\(code);\(payload)\u{1b}\\".utf8))
    }

    private func base64(_ text: String) -> String { Data(text.utf8).base64EncodedString() }

    /// 一个连上了假传输的标签（后台标签：没人看着，结果留在标签上）。
    private func connectedTab() async throws -> (TermTab, MobileTerminalController, MobileFakeTerminalHandles) {
        let (c, h, relay) = try host()
        // 不回显：真程序先把终端切成 raw 模式再查询，应答不会被回显成又一次查询。
        let (tab, handles) = MobileFakeTerminal.tab(host: h, MobileFakeTerminalScript(linesPerSecond: 0, seconds: 0,
                                                                                    corpus: .plain, echoesInput: false))
        tab.controller.isForeground = false
        tab.controller.start(profile: h, container: c, relay: relay)
        let connected = await MobileFakeTerminal.waitUntilConnected(tab.controller)
        XCTAssertTrue(connected)
        return (tab, tab.controller, handles)
    }

    func testClaudeCodePermissionFlowMatchesMac() async throws {
        let (tab, session, _) = try await connectedTab()
        defer { tab.controller.close() }

        osc(session, 7501, "state=idle:app=claude-code")
        XCTAssertNil(tab.programStatus, "空闲不上标签")

        osc(session, 7501, "state=working:app=claude-code")
        XCTAssertEqual(tab.programStatus?.state, .working)
        XCTAssertEqual(tab.programStatus?.tone, .working)

        osc(session, 7501, "state=blocked:app=claude-code:kind=permission:msg=\(base64("approve Bash: ls"))")
        XCTAssertEqual(tab.programStatus?.kind, .permission)
        XCTAssertEqual(tab.programStatus?.tone, .needsAttention)
        XCTAssertEqual(tab.programStatus?.statusLabel, "等待确认")
        XCTAssertEqual(tab.programStatus?.tabHelp, "Claude Code · 等待确认\napprove Bash: ls")

        osc(session, 7501, "state=working:app=claude-code")
        osc(session, 7501, "state=done:app=claude-code")
        XCTAssertEqual(tab.programStatus?.state, .done)

        // 切回这个标签：结果看过了。
        tab.controller.isForeground = true
        XCTAssertNil(tab.programStatus)
    }

    func testQueryIsAnsweredOnceThroughTheTransport() async throws {
        let (tab, session, handles) = try await connectedTab()
        defer { tab.controller.close() }
        let fake = try XCTUnwrap(handles.issued.first)
        osc(session, 7501, "?")
        // 应答由影子终端（vt）拟：以 `OSC 7501 ; ?` 开头，后面可以带它支持的 states / kinds，结束符和请求一致。
        let prefix = Data(ProgramStatusTracker.queryReply.dropLast(2))
        var writes: [Data] = []
        for _ in 0..<100 {
            writes = await fake.writes
            if writes.contains(where: { $0.starts(with: prefix) }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(200))
        writes = await fake.writes
        let replies = writes.filter { $0.starts(with: prefix) }
        XCTAssertEqual(replies.count, 1, "上行：\(writes.map { String(decoding: $0, as: UTF8.self).debugDescription })")
        XCTAssertEqual(replies.first?.suffix(2), Data("\u{1b}\\".utf8), "结束符和请求一致（ST）")
    }

    /// 程序被 kill -9 时来不及报告：新提示符说明它已经不在了；没看过的结果留着。
    func testNewPromptDropsRunningButKeepsUnseenResult() async throws {
        let (tab, session, _) = try await connectedTab()
        defer { tab.controller.close() }
        osc(session, 7501, "state=working:app=codex")
        osc(session, 133, "A")
        XCTAssertNil(tab.programStatus)

        osc(session, 7501, "state=done:app=codex")
        osc(session, 133, "A")
        XCTAssertEqual(tab.programStatus?.state, .done)
    }

    func testResultWhileLookingIsNotKeptAndDisconnectClears() async throws {
        let (tab, session, _) = try await connectedTab()
        tab.controller.isForeground = true
        osc(session, 7501, "state=done:app=codex")
        XCTAssertNil(tab.programStatus, "正看着时出的结果不用提示")

        osc(session, 7501, "state=blocked:app=codex")
        XCTAssertEqual(tab.programStatus?.state, .blocked, "卡住等人的照样上标签")
        tab.controller.close()
        XCTAssertNil(tab.programStatus)
        XCTAssertNil(tab.controller.programStatus)
    }

    /// 远控标签不自己解析、不回答：Mac 自己答查询并把状态推过来（见 mac 的 `RemoteProgramStatusTests`）。
    func testRemoteTabIgnoresStreamStatus() async throws {
        let (c, h, relay) = try host()
        let client = RemoteMacClient(macName: "测试 Mac", endpoint: .hostPort(host: "127.0.0.1", port: 9),
                                     identity: RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage()))
        let controller = MobileTerminalController(transportFactory: .remote(client: client, sessionID: UUID()))
        controller.isForeground = false
        controller.start(profile: h, container: c, relay: relay)
        // 等工厂把远控后端交给控制器（这台 Mac 连不上，建连随后会失败）。
        _ = await MobileFakeTerminal.waitUntil { controller.state != .connecting }
        osc(controller, 7501, "state=working:app=claude-code")
        XCTAssertNil(controller.programStatus)
        controller.close()
    }

    /// 远控标签：Mac 推来的结果到达时这个标签正看着，就当场算看过；没看着的留到切回来。
    func testRemoteResultIsSeenOnArrivalOnlyWhileLooking() async throws {
        let (c, h, relay) = try host()
        let client = RemoteMacClient(macName: "测试 Mac", endpoint: .hostPort(host: "127.0.0.1", port: 9),
                                     identity: RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage()))
        let sessionID = UUID()
        let controller = MobileTerminalController(transportFactory: .remote(client: client, sessionID: sessionID))
        controller.isForeground = false
        controller.start(profile: h, container: c, relay: relay)
        _ = await MobileFakeTerminal.waitUntil { controller.state != .connecting }
        func push(_ state: ProgramState) {
            client.receiveProgramStatus(RemoteProgramStatusUpdate(replacesAll: false, entries: [
                .init(sessionID: sessionID, status: RemoteProgramStatus(ProgramStatusRecord(state: state, app: "codex")))]))
        }

        push(.done)
        XCTAssertEqual(client.programStatus(for: sessionID)?.state, .done, "后台标签：结果留着")
        controller.isForeground = true
        XCTAssertNil(client.programStatus(for: sessionID), "切回来就算看过")

        push(.working)
        push(.error)
        XCTAssertNil(client.programStatus(for: sessionID), "正看着时到的结果当场算看过")
        push(.blocked)
        XCTAssertEqual(client.programStatus(for: sessionID)?.state, .blocked, "卡住等人的照样上标签")

        controller.close()
        push(.done)
        XCTAssertEqual(client.programStatus(for: sessionID)?.state, .done, "标签关了就不再算它在看")
    }

    /// 标签圆点的配色与 mac 的 `tabDot` 一一对应。
    func testTabDotColorsFollowTheSharedTone() {
        let accent = Color.purple
        XCTAssertEqual(WorkspaceTabChip.color(for: .needsAttention, accent: accent), M.warning)
        XCTAssertEqual(WorkspaceTabChip.color(for: .working, accent: accent), accent)
        XCTAssertEqual(WorkspaceTabChip.color(for: .done, accent: accent), M.success)
        XCTAssertEqual(WorkspaceTabChip.color(for: .failed, accent: accent), M.danger)
        XCTAssertEqual(WorkspaceTabChip.color(for: .idle, accent: accent), M.text4)
    }
}
