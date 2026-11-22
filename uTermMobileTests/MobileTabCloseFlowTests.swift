import Network
import SwiftUI
import XCTest
@testable import uTermMobile

/// 关标签前要不要问：`MTabCloseFlow` 接真控制器 + 假传输。探测结果本身见 `MobileCloseConfirmationTests`。
@MainActor
final class MobileTabCloseFlowTests: XCTestCase {
    private func connectedTab() async throws -> (TermTab, MobileFakeTerminalTransport) {
        let container = try MobileFixtures.modelContainer(seed: .smoke)
        let host = try XCTUnwrap(MobileFixtures.firstServer(in: container))
        let (tab, handles) = MobileFakeTerminal.tab(host: host, MobileFakeTerminalScript(linesPerSecond: 0, seconds: 0))
        tab.controller.start(profile: host, container: container, relay: HostKeyChallengeRelay())
        let isConnected = await MobileFakeTerminal.waitUntilConnected(tab.controller)
        XCTAssertTrue(isConnected)
        return (tab, try XCTUnwrap(handles.latest))
    }

    private func settle(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    }

    func testFilesTabClosesRightAway() {
        let flow = MTabCloseFlow()
        let tab = MWorkTab.files(FileTab(host: ServerProfile()))
        var closed: [UUID] = []

        flow.request(tab) { closed.append($0) }

        XCTAssertEqual(closed, [tab.id])
        XCTAssertNil(flow.pending)
    }

    func testBusyTabAsksInsteadOfClosing() async throws {
        let (term, transport) = try await connectedTab()
        await transport.setForegroundActivity(.running("npm"))
        let flow = MTabCloseFlow()
        var closed: [UUID] = []

        flow.request(.terminal(term)) { closed.append($0) }
        try await settle { flow.pending != nil }

        let prompt = try XCTUnwrap(TerminalActivity.running("npm").closePrompt(tabName: MWorkTab.terminal(term).title))
        XCTAssertEqual(flow.pending, MTabClosePrompt(tabID: term.id, kind: .busy(prompt)))
        XCTAssertTrue(prompt.message.contains("「\(MWorkTab.terminal(term).title)」"), "确认框要写出关的是哪个标签页")
        XCTAssertTrue(closed.isEmpty, "用户拿主意之前不能关")
        term.controller.close()
    }

    func testIdleTabClosesWithoutAsking() async throws {
        let (term, transport) = try await connectedTab()
        await transport.setForegroundActivity(.idle)
        let flow = MTabCloseFlow()
        var closed: [UUID] = []

        flow.request(.terminal(term)) { closed.append($0) }
        try await settle { !closed.isEmpty }

        XCTAssertEqual(closed, [term.id])
        XCTAssertNil(flow.pending)
        term.controller.close()
    }

    func testRepeatedTapsWhileProbingCloseOnce() async throws {
        let (term, transport) = try await connectedTab()
        await transport.setForegroundActivity(.idle)
        let flow = MTabCloseFlow()
        var closed: [UUID] = []

        for _ in 0..<3 { flow.request(.terminal(term)) { closed.append($0) } }
        try await settle { !closed.isEmpty }
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(closed, [term.id], "探测期间连点关闭只算一次")
        term.controller.close()
    }

    func testCancellingThePromptAllowsAskingAgain() async throws {
        let (term, transport) = try await connectedTab()
        await transport.setForegroundActivity(.running(nil))
        let flow = MTabCloseFlow()

        flow.request(.terminal(term)) { _ in }
        try await settle { flow.pending != nil }
        flow.pending = nil
        flow.request(.terminal(term)) { _ in }
        try await settle { flow.pending != nil }

        XCTAssertEqual(flow.pending?.tabID, term.id, "取消之后再点关闭还要再问")
        term.controller.close()
    }

    func testRemoteTabOnlyAsksWhenTheMacCanCloseItAndItIsConnected() {
        XCTAssertTrue(MTabCloseFlow.asksBeforeClosingRemote(macSupportsClosing: true, connected: true))
        XCTAssertFalse(MTabCloseFlow.asksBeforeClosingRemote(macSupportsClosing: true, connected: false))
        XCTAssertFalse(MTabCloseFlow.asksBeforeClosingRemote(macSupportsClosing: false, connected: true))
    }

    func testRemoteTabOfAnOldMacClosesRightAway() {
        let client = RemoteMacClient(macName: "老 Mac", endpoint: .hostPort(host: "127.0.0.1", port: 1),
                                     identity: RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage()))
        let sessionID = UUID()
        let term = TermTab(host: client.tabHost(for: sessionID), remote: MRemoteSource(client: client, sessionID: sessionID))
        let flow = MTabCloseFlow()
        var closed: [UUID] = []

        flow.request(.terminal(term)) { closed.append($0) }

        XCTAssertEqual(closed, [term.id], "不走探测，也不问")
        XCTAssertNil(flow.pending)
    }

    // MARK: - 标签胶囊

    private func chipWidth(_ tab: MWorkTab, activity: MTabActivity) -> CGFloat {
        let chip = WorkspaceTabChip(tab: tab, activity: activity, onSelect: {}, onClose: {})
        return UIHostingController(rootView: chip).sizeThatFits(in: CGSize(width: 600, height: 60)).width
    }

    /// 终端是常态不放图标；文件浏览标题同样是主机名，靠文件夹图标（图标框 + 6pt 间距）区分。
    func testOnlyFilesChipCarriesAnIcon() {
        let host = ServerProfile()
        host.name = "同一台主机"
        let (term, _) = MobileFakeTerminal.tab(host: host, .idle)

        let terminal = chipWidth(.terminal(term), activity: .inactive)
        let files = chipWidth(.files(FileTab(host: host)), activity: .inactive)

        XCTAssertGreaterThanOrEqual(files - terminal, 18, "多出一枚 12pt 图标和间距")
    }

    /// 后台标签不放关闭钮（触屏没有悬停，放了就是一排 ×）。
    func testOnlyFrontChipsCarryACloseButton() {
        let host = ServerProfile()
        host.name = "同一台主机"
        let (term, _) = MobileFakeTerminal.tab(host: host, .idle)
        let tab = MWorkTab.terminal(term)

        XCTAssertEqual(chipWidth(tab, activity: .active), chipWidth(tab, activity: .frontUnfocused), accuracy: 0.5)
        // 关闭钮 26pt + 间距 6pt，换掉后台标签右侧的 10pt 内边距。
        XCTAssertEqual(chipWidth(tab, activity: .active) - chipWidth(tab, activity: .inactive), 22, accuracy: 1)
    }
}
