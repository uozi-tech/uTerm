import AppKit
import SwiftUI
import XCTest
@testable import uTerm

/// 「Claude 历史会话」在**这台 Mac 的真实记录**上跑一遍：测试宿主就是沙盒里的 uTerm.app，读 `~/.claude` 走的是
/// 包内不带沙盒的辅助程序 `uTermShellAgent.xpc`，和 App 里一样。
///
/// 会读你自己的 Claude Code 记录，所以**默认跳过**，开关是 `UTERM_CLAUDE_HISTORY_LOCAL=1`
/// （xcodebuild 传环境变量要加 `TEST_RUNNER_` 前缀）。另外两个可选：
/// - `UTERM_CLAUDE_HISTORY_DIR`：一个你用过 Claude Code 的目录，核「终端在这个目录时落在对应的项目上」；
/// - `UTERM_CLAUDE_HISTORY_SAMPLE`：读多少份记录的标题（缺省 80，新的在前）。
///
/// **只读**：不往 `~/.claude` 写任何东西，也不真的启动 Claude Code（「继续这个会话」那条用例里 `claude` 是当场
/// 定义的一个 shell 函数）。日志和失败信息里只有条数、字节数和耗时，没有标题、路径或对话内容。
@MainActor
final class ClaudeHistoryLocalLiveTests: XCTestCase {
    private var client: LocalShellAgentClient!
    private var provider: RemoteMacFileProvider!
    private var scratch: URL?

    override func setUp() async throws {
        try await super.setUp()
        guard ProcessInfo.processInfo.environment["UTERM_CLAUDE_HISTORY_LOCAL"] == "1" else {
            throw XCTSkip("没设 UTERM_CLAUDE_HISTORY_LOCAL=1，跳过读本机真实记录的测试")
        }
        client = LocalShellAgentClient()
        provider = RemoteMacFileProvider.localShellAgent(client: client)
    }

    override func tearDown() async throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        client?.invalidate()
        try await super.tearDown()
    }

    private var sampleSize: Int {
        ProcessInfo.processInfo.environment["UTERM_CLAUDE_HISTORY_SAMPLE"].flatMap(Int.init) ?? 80
    }

    private func waitUntil(_ what: String, timeout: Duration = .seconds(60), _ condition: () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("等「\(what)」超时", file: file, line: line)
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// 没用过 Claude Code 的机器上跳过。
    private func loadedProjects(_ source: ClaudeHistorySource) async throws -> [AgentHistoryProject] {
        let projects = try await source.projects()
        guard !projects.isEmpty else { throw XCTSkip("这台 Mac 上没有 ~/.claude/projects") }
        return projects
    }

    // MARK: - 列表与标题

    func testReadsRealRecordsThroughTheShellAgent() async throws {
        let source = ClaudeHistorySource(provider: provider)
        var started = ContinuousClock.now
        let projects = try await loadedProjects(source)
        let listProjects = ContinuousClock.now - started

        started = ContinuousClock.now
        let all = await source.allSessions(in: projects)
        let listSessions = ContinuousClock.now - started
        XCTAssertFalse(all.isEmpty, "有项目目录却一份记录都没列出来")
        XCTAssertEqual(all.map(\.modifiedAt), all.map(\.modifiedAt).sorted(by: >), "新的在前")

        let sample = Array(all.prefix(sampleSize))
        started = ContinuousClock.now
        var listed = 0, hidden = 0, untitled = 0, resumable = 0, failed = 0
        for file in sample {
            guard let info = try? await source.metadata(for: file) else {
                failed += 1
                continue
            }
            guard info.isListed else {
                hidden += 1
                continue
            }
            listed += 1
            if info.title == nil { untitled += 1 }
            if let directory = info.resumeDirectory {
                // 记录里的目录换成项目目录名，要和它所在的项目目录对得上——这是拿真数据核换名规则。
                XCTAssertEqual(ClaudeProjectPath.encode(directory), file.project.id, "继续会话的目录和项目目录对不上")
                XCTAssertNotNil(source.resumeCommand(sessionID: file.sessionID, directory: directory))
                resumable += 1
            }
        }
        let readMetadata = ContinuousClock.now - started
        XCTAssertEqual(failed, 0, "有 \(failed) 份记录读不出标题")
        XCTAssertGreaterThan(listed, 0, "抽的 \(sample.count) 份里没有一份是命令行起的")
        print("""
            [claude-history-local] projects=\(projects.count) in \(listProjects), sessions=\(all.count) in \(listSessions), \
            sampled=\(sample.count) in \(readMetadata): listed=\(listed) hidden=\(hidden) untitled=\(untitled) resumable=\(resumable)
            """)

        // 读过的不再读：第二遍应当立刻回来。
        started = ContinuousClock.now
        for file in sample { _ = try? await source.metadata(for: file) }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(1), "第二遍读标题没走缓存")
    }

    func testTerminalDirectoryLandsOnItsProject() async throws {
        guard let directory = ProcessInfo.processInfo.environment["UTERM_CLAUDE_HISTORY_DIR"] else {
            throw XCTSkip("没设 UTERM_CLAUDE_HISTORY_DIR")
        }
        let model = AgentHistoryModel(source: ClaudeHistorySource(provider: provider), preferredDirectory: directory)
        await model.start()
        XCTAssertEqual(model.phase, .ready)
        guard case .project(let project) = model.scope else { return XCTFail("没有落在这个目录的项目上") }
        XCTAssertEqual(project.directory, directory)
        XCTAssertEqual(project.id, ClaudeProjectPath.encode(directory))
        XCTAssertFalse(model.files.isEmpty)

        // 整个项目读一遍：列出来几份、藏起来几份、读完用多久（界面是滚到哪读到哪，这里一口气读完）。
        let started = ContinuousClock.now
        var listed = 0, hidden = 0
        for file in model.files {
            let info = try await model.source.metadata(for: file)
            if info.isListed { listed += 1 } else { hidden += 1 }
        }
        print("""
            [claude-history-local] project records=\(model.files.count) listed=\(listed) hidden=\(hidden) \
            in \(ContinuousClock.now - started)
            """)
    }

    // MARK: - 对话

    /// 抽的记录里最大的一份和最新的几份：第一页读得出来，再往前翻几页不出错。
    func testOpensRealTranscripts() async throws {
        let source = ClaudeHistorySource(provider: provider)
        let projects = try await loadedProjects(source)
        let sample = Array(await source.allSessions(in: projects).prefix(sampleSize))
        var candidates: [AgentHistorySessionFile] = []
        for file in sample {
            if let info = try? await source.metadata(for: file), info.isListed { candidates.append(file) }
        }
        let largest = candidates.max { $0.size < $1.size }
        let picked = (largest.map { [$0] } ?? []) + candidates.prefix(4).filter { $0.path != largest?.path }
        XCTAssertFalse(picked.isEmpty)

        for file in picked {
            let pager = source.transcript(for: file)
            let started = ContinuousClock.now
            var items: [AgentTranscriptItem] = []
            var reachedStart = false
            var pages = 0
            while !reachedStart, pages < 6 {
                let page = try await pager.loadPrevious()
                if pages == 0 {
                    let first = ContinuousClock.now - started
                    XCTAssertLessThan(first, .seconds(3), "\(file.size) 字节的记录第一页用了 \(first)")
                }
                items = page.items + items
                reachedStart = page.reachedStart
                pages += 1
            }
            XCTAssertFalse(items.isEmpty, "\(file.size) 字节的记录一条都没读出来")
            XCTAssertEqual(Set(items.map(\.id)).count, items.count, "条目的 ID 有重复")
            let oversized = items.filter { if case .oversized = $0.kind { return true } else { return false } }.count
            print("""
                [claude-history-local] transcript bytes=\(file.size) pages=\(pages) items=\(items.count) \
                oversized=\(oversized) reachedStart=\(reachedStart) in \(ContinuousClock.now - started)
                """)
        }
    }

    // MARK: - 界面

    /// 真的列表与对话视图挂在窗口里读真数据：行露出来就去读标题、点开最大的一份能画出来，主线程不长时间卡住。
    func testBrowserViewLoadsRealDataWithoutStalling() async throws {
        let source = ClaudeHistorySource(provider: provider)
        _ = try await loadedProjects(source)
        let model = AgentHistoryModel(source: source,
                                      preferredDirectory: ProcessInfo.processInfo.environment["UTERM_CLAUDE_HISTORY_DIR"])
        await model.start()
        XCTAssertEqual(model.phase, .ready)

        let rect = NSRect(x: 0, y: 0, width: 1100, height: 720)
        let host = NSHostingView(rootView: AgentHistoryBrowser(history: model, onResume: { _ in }))
        host.frame = rect
        let window = ProbeWindow.make(contentRect: rect, contentView: host, placement: .transparentOnScreen)
        defer { window.orderOut(nil) }

        // 主线程的心跳：两拍之间最长隔了多久。
        var longestGap = Duration.zero
        let heartbeat = Task { @MainActor in
            var last = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(8))
                let now = ContinuousClock.now
                longestGap = max(longestGap, now - last)
                last = now
            }
        }
        defer { heartbeat.cancel() }

        // 第一批：列表里有了一屏多的行，或者整个范围读完了。
        await waitUntil("第一批会话") { model.visibleFiles.count >= 24 || !model.hasMore }
        // 没人滚动：读得停下来。懒加载的列表会把视口下面不远的那行「正在读取」也先建出来，所以会多预取一批，
        // 但不能一路读到底（改之前会：列表还短时那一行一直露着，每多一行催一次，主线程因此卡过 5 秒）。
        var settled = model.visibleFiles.count
        var stableSince = ContinuousClock.now
        let settleDeadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now - stableSince < .seconds(1), ContinuousClock.now < settleDeadline {
            try await Task.sleep(for: .milliseconds(50))
            if model.visibleFiles.count != settled {
                settled = model.visibleFiles.count
                stableSince = ContinuousClock.now
            }
        }
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - stableSince, .seconds(1), "没人滚动，列表却一直在往后读")
        if model.files.count > 200 {
            XCTAssertTrue(model.hasMore, "\(model.files.count) 份记录没滚动就全读了")
        }
        // 列出来的每一行都已经有信息：没有占位行，之后也不会消失。
        XCTAssertTrue(model.visibleFiles.allSatisfy { model.metadata[$0.path]?.isListed == true })
        let before = model.visibleFiles.map(\.path)

        // 往下滚到底一次：再来一批，先前的行原样还在。
        model.loadMore()
        await waitUntil("下一批会话") { model.visibleFiles.count >= settled + 24 || !model.hasMore }
        XCTAssertEqual(Array(model.visibleFiles.map(\.path).prefix(before.count)), before)
        print("[claude-history-local] list: settled at \(settled) rows without scrolling, \(model.visibleFiles.count) after one more batch, of \(model.files.count) records")

        // 挨个点开最大的几份：第一页读得出来，画的时候主线程不长时间卡住。
        let targets = model.visibleFiles.sorted { $0.size > $1.size }.prefix(4)
        XCTAssertFalse(targets.isEmpty, "没有命令行起的会话")
        for target in targets {
            let started = ContinuousClock.now
            longestGap = .zero
            model.select(target)
            let transcript = try XCTUnwrap(model.transcript)
            await waitUntil("对话的第一页") { !transcript.items.isEmpty || transcript.errorMessage != nil }
            XCTAssertNil(transcript.errorMessage)
            let loaded = ContinuousClock.now - started
            // 让视图把这一页画完，再往前翻一页。
            try await Task.sleep(for: .seconds(1))
            if !transcript.reachedStart {
                await transcript.loadEarlier()
                try await Task.sleep(for: .milliseconds(500))
            }
            print("""
                [claude-history-local] view: rows=\(model.visibleFiles.count)/\(model.files.count) \
                opened bytes=\(target.size) items=\(transcript.items.count) first page in \(loaded), \
                longest main-thread gap \(longestGap)
                """)
            XCTAssertLessThan(longestGap, .seconds(1), "打开 \(target.size) 字节的对话时主线程卡了 \(longestGap)")
        }
    }

    // MARK: - 继续这个会话

    /// 真的登录 shell（你的 zsh 配置都在）里执行那条命令：先进项目目录，再带 `--resume <ID>` 调 `claude`。
    func testResumeCommandRunsInARealLoginShell() async throws {
        // 目录带空格、单引号、中文。建在测试宿主自己的临时目录里（沙盒只让写这里），不带沙盒的 shell 进得去。
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("uterm-claude-history-e2e-" + UUID().uuidString.prefix(8).lowercased())
        scratch = root
        let project = root.appendingPathComponent("it's a 项目")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let record = root.appendingPathComponent("record.txt")
        let sessionID = "22222222-aaaa-4bbb-8ccc-000000000001"
        let command = try XCTUnwrap(ClaudeResumeCommand.make(sessionID: sessionID, directory: project.path))

        let backend = LocalShellBackend(client: client, namespace: "integration-test", columns: 120, rows: 30)
        let session = TerminalSession()
        await session.connect(using: backend)
        XCTAssertEqual(session.connectionState, .connected)
        defer { session.dispose() }

        // 假的 `claude`：把所在目录和参数一行一个记下来。写成函数，不碰你装的那个，也不受别名影响。
        let quotedRecord = "'" + record.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        session.sendHostBytes(Data(
            " unalias claude 2>/dev/null; function claude { { pwd -P; printf '%s\\n' \"$@\"; } > \(quotedRecord); }\n".utf8))

        session.startTrackedRun(command, inSubshell: false)
        await waitUntil("命令跑完") {
            if case .finished = session.trackedRun?.phase { return true }
            return false
        }
        XCTAssertEqual(session.trackedRun?.phase, .finished(0))

        let recorded = try String(contentsOf: record, encoding: .utf8)
        XCTAssertEqual(recorded.split(separator: "\n").map(String.init),
                       [project.resolvingSymlinksInPath().path, "--resume", sessionID])
        // 「退出」之后 shell 还在项目目录里。
        let current = await backend.workingDirectory()
        XCTAssertEqual(current.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
                       project.resolvingSymlinksInPath().path)
        await backend.close()
    }
}
