import Network
import SwiftUI
import XCTest
@testable import uTermMobile

/// 配对的 Mac 上，Code 标签页「＋」新开会话，对着 Mac 上的联调服务（`RemoteCodeTabHarnessTests`）真走一遍：
/// - 主目录是经远控文件通道问到的那台 Mac 的；候选里补上 Mac 最近的工作区；
/// - 输入路径经那台 Mac 的文件服务核对（存在 / 不存在 / 是文件 / `~` 展开）；
/// - 「开始」请 Mac 在选的目录开本机终端，接管它，行编辑器起来后打进新会话的命令（Mac 那头回显）。
///
/// 默认跳过：经 `xcodebuild test-without-building` 传 `TEST_RUNNER_UTERM_HARNESS_PORT=<端口>` 时才运行。
/// 模拟器与 Mac 共用网络栈，直连 127.0.0.1。列记录用的是真的 Claude Code 数据源，但指向一个不存在的主目录：
/// 不去读那台 Mac 上真实的会话记录。
@MainActor
final class CodeTabPairedMacRealTests: XCTestCase {
    private let chosen = "/Library/Application Support"

    func testNewSessionOnAPairedMacPicksADirectoryAndOpensTheShellThere() async throws {
        guard let raw = ProcessInfo.processInfo.environment["UTERM_HARNESS_PORT"],
              let port = NWEndpoint.Port(raw) else {
            throw XCTSkip("没有设置 UTERM_HARNESS_PORT，跳过")
        }
        let client = RemoteMacClient(macName: "Code 联调 Mac", endpoint: .hostPort(host: "127.0.0.1", port: port),
                                     identity: RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage()))
        defer { client.disconnect() }
        let store = MobileStore()
        let workspace = MobileWorkspace()
        let (window, _) = MobileProbeWindow.make(
            size: CGSize(width: 390, height: 844),
            rootView: AnyView(WorkspaceScreen()
                .environment(store)
                .environment(HostKeyChallengeRelay())
                .environment(workspace)
                .modelContainer(try MobileFixtures.emptyContainer())))
        defer { window.isHidden = true }

        await client.connect()
        XCTAssertEqual(client.state, .connected)
        XCTAssertTrue(client.supportsLocalShell, "能新建本机终端：才有「＋」")
        XCTAssertTrue(client.supportsFiles)

        // 同 `ClaudeHistoryTab(pairedMac:)`，只是记录读一个不存在的主目录下的（列出来是空的）。
        let connection = AgentHistoryConnection(
            preferredDirectory: nil, tools: [.claude], followsCurrentProject: false,
            makeSource: { provider, _ in ClaudeHistorySource(provider: provider, home: "/nonexistent-uterm-code-e2e") },
            connect: AgentHistoryAccess.pairedMac(client))
        let tab = ClaudeHistoryTab(host: client.filesTabHost, connection: connection, remoteMac: client)
        defer { tab.close() }
        XCTAssertTrue(tab.canResume)
        tab.start()
        try await waitUntil("列表") { connection.history.map { !$0.isListing } ?? false }
        try await waitUntil("问到 Mac 的主目录") { connection.homeDirectory != nil }
        let home = try XCTUnwrap(connection.homeDirectory)
        XCTAssertTrue(home.hasPrefix("/Users/"), "那台 Mac 上用户的主目录，不是测试宿主的沙盒容器")
        XCTAssertFalse(home.contains("/Library/Containers/"))

        // 「＋」：弹面板；没有目录（远控协议里没有终端的当前目录），候选里补上 Mac 最近的工作区。
        tab.presentNewSession()
        let draft = try XCTUnwrap(tab.newSessionDraft)
        XCTAssertNil(draft.directory)
        try await waitUntil("补上 Mac 的工作区") { draft.choices.contains(self.chosen) }
        XCTAssertEqual(draft.choices, [chosen, "/usr/share", home], "工作区在前，主目录最后")
        XCTAssertEqual(draft.display(home + "/x"), "~/x")

        // 输入路径：经那台 Mac 的文件服务核对。
        func submit(_ text: String) async -> (String?, AgentHistoryDirectoryInput.Problem?) {
            let entry = AgentHistoryPathEntry(text: text)
            let path = await entry.submit(using: connection)
            return (path, entry.problem)
        }
        var result = await submit("~/Library")
        XCTAssertEqual(result.0, home + "/Library", "~ 照那台 Mac 的主目录展开")
        result = await submit("/etc/hosts")
        if case .notDirectory = result.1 {} else { XCTFail("是文件：\(String(describing: result.1))") }
        let missing = "/uterm-code-e2e-\(UUID().uuidString)"
        result = await submit(missing)
        XCTAssertEqual(result.1, .missing(missing))
        result = await submit(chosen + "/")
        XCTAssertEqual(result.0, chosen)

        // 「开始」：同面板里点开始（`ClaudeHistorySessionBody.startNewSession` → 配对的 Mac 走 `runInNewTerminal`）。
        draft.directory = chosen
        let history = try XCTUnwrap(connection.history)
        XCTAssertEqual(history.newSessionTools(directory: chosen), [.claude])
        let command = try XCTUnwrap(history.newSessionCommand(tool: .claude, directory: chosen))
        XCTAssertEqual(command, "cd -- '\(chosen)' && claude")
        tab.chooseNewSessionDirectory(chosen)
        tab.newSessionDraft = nil
        try await tab.runInNewTerminal(command, directory: chosen, store: store)

        try await waitUntil("Mac 上开的终端") { client.sessions.contains { $0.title == "zsh · \(self.chosen)" } }
        try await waitUntil("接管它") { workspace.terminalTabs.first?.controller.state == .connected }
        store.finishConnect()
        let terminal = try XCTUnwrap(workspace.terminalTabs.first)
        try await waitUntil("命令打进去了（Mac 回显）") {
            terminal.controller.terminal.shadow.viewportText().contains("cd -- '\(self.chosen)' && claude")
        }
        XCTAssertEqual(tab.directory, chosen, "之后「＋」默认开在这里")
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 20, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("等「\(what)」超时") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
