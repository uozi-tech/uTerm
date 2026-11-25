import AppKit
import SwiftUI
import XCTest
@testable import uTerm

/// 本机终端窗口的 Code 标签页：起始页上选了一个目录（「选择文件夹…」的系统面板只交回一个路径字符串，这里从
/// 它之后接上），点「开始」，会话的 shell 真的进了那个目录。
///
/// 用真的保持进程 + 真 shell，会话放在测试自己的命名空间里（同 `CodeTabRunExitTests`）。「编码工具」换成
/// `pwd; head -n 1`：先把 shell 所在的目录打到屏上，再等一行输入就退出。命令前面的 `cd -- '<目录>'` 用真的
/// 引号规则（`ClaudeResumeCommand.quotedDirectory`）。
///
/// 目录有三种：测试自己建的、名字里带空格 / 单引号 / 中文 / `#` 的；用户的主目录和 `/Library/Application Support`
/// ——这两个在测试宿主的沙盒外面（文件夹面板选到的通常就是这种），宿主自己进不去，shell 由辅助程序在沙盒外起，要能进。
@MainActor
final class CodeTabNewSessionShellTests: XCTestCase {
    private static let namespace = "integration-test"
    private let client = LocalShellAgentClient()
    private var sessionIDs: Set<UUID> = []

    override func tearDown() async throws {
        for id in sessionIDs { await HolderProbe.terminate(id, client: client, namespace: Self.namespace) }
        client.invalidate()
        try await super.tearDown()
    }

    func test_start_runs_the_shell_in_the_chosen_directory() async throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("uTerm 新会话 it's #\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let home = String(cString: try XCTUnwrap(getpwuid(getuid())).pointee.pw_dir)
        XCTAssertNotEqual(home, NSHomeDirectory(), "测试宿主带沙盒，NSHomeDirectory 是容器")

        for target in [base.path, home, "/Library/Application Support"] {
            try await runIn(target)
        }
    }

    private func runIn(_ chosen: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let model = LocalShellWindowModel(startShell: { [weak self] pane in
            guard let self else { return }
            self.sessionIDs.insert(pane.id)
            let backend = LocalShellBackend(client: self.client, namespace: Self.namespace, sessionID: pane.id,
                                            directory: pane.workingDirectory, columns: 100, rows: 24)
            Task { await pane.session.connect(using: backend) }
        })
        let registry = TerminalSessionRegistry()
        model.attach(TerminalSessionRegistrar(registry: registry, windowID: UUID(), windowKind: TerminalWindowKind.terminal))
        let window = ProbeWindow.make(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600),
                                      key: true, placement: .transparentOnScreen)
        let host = NSHostingView(rootView: LocalShellTerminalArea(model: model))
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)
        window.contentView = host
        defer {
            model.disposeAll()
            window.contentView = NSView()
            window.orderOut(nil)
        }

        // 标签页是在别的目录里打开的；起始页上换成选的那个。
        let opened = ClaudeProjectPath.normalized(NSTemporaryDirectory()) ?? NSTemporaryDirectory()
        let codeID = model.openCodeTab(directory: opened)
        let code = try XCTUnwrap(model.groups.tab(codeID)?.payload.codeTab)
        code.install(await connection(command: "pwd; head -n 1", directory: opened))
        XCTAssertEqual(code.detail, .empty, "右边是起始页", file: file, line: line)

        code.chooseNewSessionDirectory(chosen)   // 同起始页：面板交回的路径
        let directory = try XCTUnwrap(code.newSessionDirectory, file: file, line: line)
        let started = try XCTUnwrap(code.startNewSession(tool: .claude, in: directory), file: file, line: line)
        let run = try XCTUnwrap(model.pane(started.id), file: file, line: line)
        await wait("会话里的命令跑起来") { await run.session.foregroundActivity() == .running("head") }

        let expected = Self.resolved(chosen)
        let backend = try XCTUnwrap(run.session.backend as? LocalShellBackend, file: file, line: line)
        let cwd = await backend.workingDirectory()
        XCTAssertEqual(cwd.map(Self.resolved), expected, "shell 在选的目录里：\(chosen)", file: file, line: line)
        let screen = run.session.shadow.viewportText()
        XCTAssertTrue(screen.split(separator: "\n").contains { Self.resolved(String($0).trimmingCharacters(in: .whitespaces)) == expected },
                      "屏上打出了 pwd：\(screen)", file: file, line: line)
        XCTAssertFalse(screen.contains("no such file"), "cd 没报错：\(screen)", file: file, line: line)

        run.session.writeRemoteInput(Data("bye\n".utf8))
        // 新会话没有对话记录：终端留着、标成已结束（见 `CodeTabRunExitTests`）。
        await wait("会话收尾") { code.runs.first { $0.id == run.id }?.isEnded ?? true }
        XCTAssertEqual(model.groups.allTabs.map(\.id), [codeID], file: file, line: line)
        XCTAssertEqual(code.newSessionDirectory, directory, "选的目录留着，下次新开还在这里", file: file, line: line)
    }

    /// 比较用：解开符号链接（`/var` → `/private/var`），去掉末尾的 `/`。
    private static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private func connection(command: String, directory: String) async -> AgentHistoryConnection {
        let source = AgentHistoryFakeSource(tool: .claude, sessions: [
            AgentHistoryFakeSource.Session(id: "a", projectID: ClaudeProjectPath.encode(directory),
                                           resumeDirectory: directory, title: "假的会话",
                                           modifiedAt: Date().addingTimeInterval(-3600)),
        ], command: command)
        let history = AgentHistoryModel(source: source, preferredDirectory: directory, followsCurrentProject: false)
        await history.start()
        for _ in 0..<200 where history.hasMore || history.isListing { try? await Task.sleep(for: .milliseconds(10)) }
        return AgentHistoryConnection(history: history)
    }

    private func wait(_ what: String, timeout: TimeInterval = 20, for condition: () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let met = await condition()
        XCTAssertTrue(met, "等不到：\(what)")
    }
}
