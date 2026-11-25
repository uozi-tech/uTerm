import XCTest
@testable import uTerm

/// 端到端：Code 标签页里真的起本机 shell（真的 `uterm-holder` + 登录 shell）跑命令，模拟 App 重启（断开连接、丢掉整个
/// 窗口模型，按保持进程里存的归属重建），会话回到 Code 标签页里；App 不在时跑完了的那条命令，接回后认出来并收尾。
///
/// 会话放在测试自己的命名空间里（同 `LocalShellHolderIntegrationTests`），不碰正式版与开发版的会话。
@MainActor
final class CodeTabHolderRestoreTests: XCTestCase {
    private static let namespace = "integration-test"
    private let client = LocalShellAgentClient()
    private var sessionIDs: Set<UUID> = []

    override func tearDown() async throws {
        for id in sessionIDs { await HolderProbe.terminate(id, client: client, namespace: Self.namespace) }
        client.invalidate()
        try await super.tearDown()
    }

    /// 和 `LocalShellPane.start()` 一样：连上之后把归属写进保持进程，只是用测试的命名空间。
    private func model(windowID: UUID) -> LocalShellWindowModel {
        let model = LocalShellWindowModel(startShell: { [weak self] pane in
            guard let self else { return }
            self.sessionIDs.insert(pane.id)
            let backend = LocalShellBackend(client: self.client, namespace: Self.namespace, sessionID: pane.id,
                                            directory: pane.workingDirectory, columns: 80, rows: 24)
            Task {
                await pane.session.connect(using: backend)
                if let attributes = pane.attributes, let data = try? JSONEncoder().encode(attributes) {
                    await backend.setAttributes(data)
                }
            }
        })
        model.attach(TerminalSessionRegistrar(registry: TerminalSessionRegistry(), windowID: windowID,
                                              windowKind: TerminalWindowKind.terminal))
        return model
    }

    private func wait(timeout: TimeInterval = 15, for condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return await condition()
    }

    private func stored(_ id: UUID) async -> LocalShellSessionAttributes? {
        guard let reply = await HolderProbe.hello(id, client: client, namespace: Self.namespace) else { return nil }
        return try? JSONDecoder().decode(LocalShellSessionAttributes.self, from: Data(reply.attributes))
    }

    func test_code_tab_runs_come_back_into_the_code_tab_after_restart() async throws {
        let windowID = UUID()
        let directory = NSTemporaryDirectory()
        let before = model(windowID: windowID)
        let codeID = before.openCodeTab(directory: directory)
        let code = try XCTUnwrap(before.groups.tab(codeID)?.payload.codeTab)
        // 一个一直在跑，一个在 App 不在时跑完。
        let long = try XCTUnwrap(code.startNewSession(tool: .claude, command: "sleep 600", directory: directory))
        let short = try XCTUnwrap(code.startNewSession(tool: .codex, command: "sleep 4", directory: directory))
        let longPane = try XCTUnwrap(before.pane(long.id)), shortPane = try XCTUnwrap(before.pane(short.id))
        for pane in [longPane, shortPane] {
            let running = await wait { await pane.session.foregroundActivity() == .running("sleep") }
            XCTAssertTrue(running, "命令没在 Code 标签页的 shell 里跑起来")
        }
        let written = await wait {
            for id in [long.id, short.id] {
                guard let layout = await self.stored(id)?.layout,
                      layout.tree.groups.first?.tabs == [codeID],
                      layout.codeTabs?.first?.runs.map(\.session) == [long.id, short.id],
                      layout.codeTabs?.first?.runs.allSatisfy({ $0.marker != nil }) == true else { return false }
            }
            return true
        }
        XCTAssertTrue(written, "布局（含 Code 标签页）没写进保持进程")

        // App 退出：只断开，shell 留着（同 `TerminalQuitPolicy`）；整个窗口模型丢掉。
        for pane in [longPane, shortPane] {
            await (pane.session.backend as? LocalShellBackend)?.detach()
            pane.session.detach()
        }
        // App 不在的这段时间里，短的那条命令跑完、回到提示符（shell 还在）。
        try await Task.sleep(for: .seconds(5))

        let restorer = LocalShellRestorer(client: client, namespace: Self.namespace, gateTimeout: .milliseconds(50),
                                          reopenDelay: .milliseconds(10))
        restorer.install { _, _ in }
        await restorer.restore()
        let after = model(windowID: windowID)
        restorer.adoptPending(windowID: windowID, into: after)

        XCTAssertEqual(after.groups.allTabs.map(\.id), [codeID], "Code 标签页回来了，里面的会话没变成普通标签页")
        let back = try XCTUnwrap(after.groups.tab(codeID)?.payload.codeTab)
        XCTAssertEqual(back.runs.map(\.id), [long.id, short.id], "会话回到这个标签页里")
        XCTAssertEqual(back.runs.map(\.tool), [.claude, .codex])

        let ended = await wait { back.runs.first { $0.id == short.id }?.terminal.codeCommandHasEnded == true }
        XCTAssertTrue(ended, "App 不在时跑完的命令：接回后认出来")
        let longPaneAfter = try XCTUnwrap(after.pane(long.id))
        let stillRunning = await wait { await longPaneAfter.session.foregroundActivity() == .running("sleep") }
        XCTAssertTrue(stillRunning, "还在跑的那个接回的是同一个 shell")
        XCTAssertFalse(longPaneAfter.codeCommandHasEnded, "还在跑的不能被当成结束")
        back.checkRuns()
        // 这里没有列表（不知道有没有对话记录）：跑完的标成已结束、终端留着（见 `CodeTabRunExitTests`），还在跑的照跑。
        XCTAssertEqual(back.runs.map(\.id), [long.id, short.id])
        XCTAssertEqual(back.runs.map(\.isEnded), [false, true], "跑完的收尾，还在跑的留着")
        XCTAssertEqual(back.runningCount, 1)

        after.disposeAll()
    }
}
