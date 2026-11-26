import XCTest
@testable import uTerm

/// Code 标签页镜像另一台 Mac 的 Code 标签页（Mac 控制 Mac，`CodeTabModel+Mirror`）：镜像来的会话这边不认记录、不看程序退出；
/// 继续、新开、重新开始、移到新标签页发 64 号消息（字段对）、做完的会话出现时选上（回复先到后到都行）；结束发 8 号消息；
/// 老 Mac 的继续 / 新开在它上面新开终端，重新开始不给。64 / 8 号消息与终端都是假的。
@MainActor
final class CodeTabMirrorModelTests: XCTestCase {
    private final class FakeTerminal: CodeTabTerminal {
        let id: UUID
        private(set) var disposed = false
        var codeCommandHasEnded = false
        init(id: UUID = UUID()) { self.id = id }
        func runCodeCommand(_ command: String) {}
        func dispose() { disposed = true }
    }

    private typealias Session = AgentHistoryFakeSource.Session
    private static let shop = "/srv/shop"

    private var performed: [RemoteCodeTabAction] = []
    private var ended: [UUID] = []
    private var inNewTerminal: [(command: String, directory: String)] = []
    private var reply: UUID?
    private var supportsActions = true
    private var madeLocally = 0
    private var terminals: [UUID: FakeTerminal] = [:]

    private func makeCode(sessions: [Session] = []) async -> (CodeTabModel, AgentHistoryModel) {
        let source = AgentHistoryFakeSource(tool: .claude, sessions: sessions)
        let history = AgentHistoryModel(source: source, preferredDirectory: Self.shop, followsCurrentProject: false)
        await history.start()
        for _ in 0..<200 where history.hasMore || history.isListing { try? await Task.sleep(for: .milliseconds(10)) }
        let remote = CodeTabRemote(
            supportsActions: { [unowned self] in supportsActions },
            perform: { [unowned self] action in
                performed.append(action)
                guard let reply else { throw RemoteAttachError.rejected("那台 Mac 做不成") }
                return reply
            },
            end: { [unowned self] in ended.append($0) },
            runInNewTerminal: { [unowned self] command, directory in inNewTerminal.append((command, directory)) })
        remote.macTabID = Self.macTab
        let code = CodeTabModel(hostName: "测试 Mac", directory: Self.shop, remote: remote) { [unowned self] _ in
            madeLocally += 1
            return FakeTerminal()
        }
        code.install(AgentHistoryConnection(history: history))
        return (code, history)
    }

    private static let macTab = UUID()

    private func mirrored(_ id: UUID, path: String? = nil, sessionID: String? = nil, title: String? = nil,
                          ended: Date? = nil) -> RemoteCodeTabInfo.Run {
        RemoteCodeTabInfo.Run(session: id, tool: AgentHistoryTool.claude.rawValue, directory: Self.shop,
                              startedAt: Date().addingTimeInterval(-30), sessionID: sessionID, path: path, title: title,
                              endedAt: ended)
    }

    private func adopt(_ code: CodeTabModel, _ runs: [RemoteCodeTabInfo.Run]) {
        code.addMirroredRuns(runs) { [unowned self] id in
            let terminal = FakeTerminal(id: id)
            terminals[id] = terminal
            return terminal
        }
    }

    private func session(_ id: String, title: String?, ago seconds: TimeInterval) -> Session {
        Session(id: id, projectID: ClaudeProjectPath.encode(Self.shop), resumeDirectory: Self.shop, title: title,
                modifiedAt: Date().addingTimeInterval(-seconds))
    }

    // MARK: 这边不认记录、不看退出

    func testMirroredRunsAreNotMatchedOrEndedLocally() async throws {
        // 一份刚写出来的记录，目录、工具都对得上：本机起的新会话会对上它，镜像来的不对（那台 Mac 去对）。
        let (code, history) = await makeCode(sessions: [session("fresh", title: "刚写的", ago: 0)])
        let a = UUID()
        adopt(code, [mirrored(a, title: "Mac 上的名字")])
        let run = try XCTUnwrap(code.runs.first)
        XCTAssertTrue(run.isMirrored)
        XCTAssertFalse(run.isUnmatched)

        terminals[a]?.codeCommandHasEnded = true
        code.checkRuns()
        code.matchNewSessions()
        await code.refreshList()
        XCTAssertEqual(code.runs.map(\.id), [a], "程序退出由那台 Mac 报，这边不收尾")
        XCTAssertNil(code.runs.first?.path, "不去对记录")
        XCTAssertNil(code.runs.first?.endedAt)
        XCTAssertEqual(terminals[a]?.disposed, false)
        XCTAssertEqual(code.title(of: try XCTUnwrap(code.runs.first)), "Mac 上的名字")
        XCTAssertFalse(history.files.isEmpty)

        // 那台 Mac 报结束、对上了记录：照它改，列表里有这份记录也不在这边收尾。
        let file = try XCTUnwrap(history.files.first)
        code.applyMirrorUpdates([mirrored(a, path: file.path, sessionID: file.sessionID, title: "新名字", ended: Date())])
        code.applyRestoredState()
        XCTAssertEqual(code.runs.first?.path, file.path)
        XCTAssertNotNil(code.runs.first?.endedAt)
        XCTAssertEqual(code.runs.count, 1)
        XCTAssertEqual(code.title(of: try XCTUnwrap(code.runs.first)), "新名字")

        // 那台 Mac 上没了：拿掉、断开接入。
        code.removeMirroredRuns([a])
        XCTAssertTrue(code.runs.isEmpty)
        XCTAssertEqual(terminals[a]?.disposed, true)
    }

    // MARK: 请那台 Mac 做

    /// 继续：发 64（resume，带 Mac 上的 Code 标签页、记录、继续目录），这边不起终端。回复先到、会话后出现：出现时选上。
    func testResumeAsksTheMacAndFocusesTheRunWhenItAppears() async throws {
        let (code, history) = await makeCode(sessions: [session("a", title: "登录接口", ago: 60)])
        let file = try XCTUnwrap(history.files.first)
        let newRun = UUID()
        reply = newRun

        XCTAssertNil(code.resume(file), "这边不起")
        await code.remote?.lastAction?.value
        XCTAssertEqual(madeLocally, 0)
        let action = try XCTUnwrap(performed.first)
        XCTAssertEqual(action.knownAction, .resume)
        XCTAssertEqual(action.tab, Self.macTab)
        XCTAssertEqual(action.path, file.path)
        XCTAssertEqual(action.tool, AgentHistoryTool.claude.rawValue)
        XCTAssertEqual(action.sessionID, "a")
        XCTAssertEqual(action.directory, Self.shop)
        XCTAssertNil(action.server, "Mac 本机的 Code 标签页")
        XCTAssertEqual(code.remote?.pendingFocus, newRun, "还没出现：记着")

        adopt(code, [mirrored(newRun, path: file.path, sessionID: "a")])
        XCTAssertNil(code.remote?.pendingFocus)
        XCTAssertEqual(code.displayedRun?.id, newRun, "出现了就选上")
        XCTAssertEqual(code.detail, .terminal(newRun))
    }

    /// 新开：发 64（start，带工具与目录）。会话先出现（63 先于回复）：回复一到就选上。
    func testStartAsksTheMacAndFocusesARunThatIsAlreadyThere() async throws {
        let (code, _) = await makeCode()
        let newRun = UUID()
        adopt(code, [mirrored(newRun)])
        XCTAssertNil(code.displayedRun)
        reply = newRun

        XCTAssertNil(code.startNewSession(tool: .claude, command: "claude", directory: "/srv/infra"))
        await code.remote?.lastAction?.value
        XCTAssertEqual(madeLocally, 0)
        let action = try XCTUnwrap(performed.first)
        XCTAssertEqual(action.knownAction, .start)
        XCTAssertEqual(action.tab, Self.macTab)
        XCTAssertEqual(action.tool, AgentHistoryTool.claude.rawValue)
        XCTAssertEqual(action.directory, "/srv/infra")
        XCTAssertNil(code.remote?.pendingFocus)
        XCTAssertEqual(code.displayedRun?.id, newRun)
    }

    func testRestartAndMoveToTabAskTheMac() async throws {
        let (code, _) = await makeCode()
        let (done, running, fresh) = (UUID(), UUID(), UUID())
        adopt(code, [mirrored(done, ended: Date()), mirrored(running)])
        XCTAssertTrue(code.canRestart(done))

        reply = fresh
        XCTAssertNil(code.restart(done))
        await code.remote?.lastAction?.value
        XCTAssertEqual(performed.last?.knownAction, .restart)
        XCTAssertEqual(performed.last?.session, done)
        XCTAssertEqual(performed.last?.tab, Self.macTab)
        XCTAssertEqual(code.runs.map(\.id), [done, running], "换不换由那台 Mac 推来的 Code 标签页定")
        XCTAssertEqual(terminals[done]?.disposed, false)

        reply = running
        var moved: UUID?
        code.moveToTabOnRemote(running) { moved = $0 }
        await code.remote?.lastAction?.value
        XCTAssertEqual(performed.last?.knownAction, .moveToTab)
        XCTAssertEqual(performed.last?.session, running)
        XCTAssertEqual(moved, running)

        // 已结束的不能移、跑着的不能重新开始。
        let count = performed.count
        code.moveToTabOnRemote(done) { _ in }
        _ = code.restart(running)
        XCTAssertEqual(performed.count, count)
    }

    /// 结束会话、关掉已结束的会话：都请那台 Mac 结束它（8 号消息），这边等它推来新的 Code 标签页再拿掉。
    func testEndingAMirroredRunAsksTheMac() async throws {
        let (code, _) = await makeCode()
        let (running, done) = (UUID(), UUID())
        adopt(code, [mirrored(running), mirrored(done, ended: Date())])
        code.endSession(running)
        code.dismissEnded(done)
        XCTAssertTrue(code.end(done))
        XCTAssertEqual(ended, [running, done, done])
        XCTAssertEqual(code.runs.count, 2)
        XCTAssertEqual(terminals[running]?.disposed, false)
        XCTAssertTrue(performed.isEmpty)
    }

    /// 那台 Mac 太旧、不认 64：继续、新开在它上面新开一个本机终端（今天的做法）；重新开始、移到新标签页不给。
    func testOldMacRunsInANewTerminalAndCannotRestart() async throws {
        supportsActions = false
        let (code, history) = await makeCode(sessions: [session("a", title: "t", ago: 60)])
        let file = try XCTUnwrap(history.files.first)
        _ = code.resume(file)
        await code.remote?.lastAction?.value
        _ = code.startNewSession(tool: .claude, command: "claude", directory: Self.shop)
        await code.remote?.lastAction?.value
        XCTAssertTrue(performed.isEmpty)
        XCTAssertEqual(inNewTerminal.map(\.directory), [Self.shop, Self.shop])
        XCTAssertEqual(inNewTerminal.first?.command, "cd -- '\(Self.shop)' && claude resume a")
        XCTAssertEqual(inNewTerminal.last?.command, "claude")
        XCTAssertEqual(madeLocally, 0)

        let done = UUID()
        adopt(code, [mirrored(done, ended: Date())])
        XCTAssertFalse(code.canRestart(done))
        _ = code.restart(done)
        code.moveToTabOnRemote(done) { _ in }
        XCTAssertTrue(performed.isEmpty)
    }

    /// 那台 Mac 做不成：记下给人看的原因，界面弹提示。
    func testFailureIsReported() async throws {
        reply = nil
        let (code, _) = await makeCode()
        _ = code.startNewSession(tool: .claude, command: "claude", directory: Self.shop)
        await code.remote?.lastAction?.value
        XCTAssertEqual(code.remote?.failure?.message, "那台 Mac 做不成")
        XCTAssertEqual(code.remote?.actionInFlight, false)
    }

    /// 第一次开出这个镜像时照那台 Mac 右边看着的选。
    func testAdoptsTheMacSelectionOnce() async throws {
        let (code, _) = await makeCode()
        let (a, b) = (UUID(), UUID())
        adopt(code, [mirrored(a), mirrored(b)])
        let info = RemoteCodeTabInfo(id: Self.macTab, serverID: RemoteConstants.localShellServerID, serverName: "本机",
                                     directory: Self.shop, slot: 0, runs: [mirrored(a), mirrored(b)], selectedRun: b,
                                     selectedRecord: nil)
        code.adoptMacSelection(of: info)
        XCTAssertEqual(code.displayedRun?.id, b)

        code.stopMirroring()
        XCTAssertTrue(code.runs.isEmpty)
        XCTAssertNil(code.remote?.macTabID)
        XCTAssertEqual(terminals[a]?.disposed, true)
    }
}
