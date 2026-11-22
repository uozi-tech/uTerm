import XCTest
@testable import uTerm

/// 终端里的程序请 uTerm 在旁边预览文件（OSC 6975，`TerminalFilePreview`）：解析、节流、会话里的接线、预览区的打开方式。
@MainActor
final class TerminalFilePreviewTests: XCTestCase {

    // MARK: 解析

    private func parse(_ payload: String) -> String? {
        TerminalFilePreview.path(fromOSC: Data(payload.utf8))
    }

    func testParsesAbsolutePath() {
        XCTAssertEqual(parse("6975;open;/srv/app/docs/plan.md"), "/srv/app/docs/plan.md")
        XCTAssertEqual(parse("6975;open;/tmp/a b;c.png"), "/tmp/a b;c.png", "路径里的空格、分号原样保留")
        XCTAssertEqual(parse("6975;open;/home/用户/图.png"), "/home/用户/图.png")
        XCTAssertEqual(parse("6975;open;/srv/docs/"), "/srv/docs", "末尾的 / 去掉")
    }

    func testRejectsMalformedRequests() {
        XCTAssertNil(parse("6975;open;docs/plan.md"), "相对路径：程序那边该自己拼好")
        XCTAssertNil(parse("6975;open;/"))
        XCTAssertNil(parse("6975;open;"))
        XCTAssertNil(parse("6975;open;/tmp/a\u{1B}[31m.md"), "带控制字符")
        XCTAssertNil(parse("6975;open;/tmp/a\nb.md"))
        XCTAssertNil(parse("6975;close;/tmp/a.md"), "不认识的动作")
        XCTAssertNil(parse("6973;S;deadbeef"), "别的私有 OSC")
        XCTAssertNil(parse("6975;open;/" + String(repeating: "a", count: TerminalFilePreview.maxPathBytes)))
        XCTAssertNil(TerminalFilePreview.path(fromOSC: Data("6975;open;/a".utf8) + Data([0xFF, 0xFE])), "不是 UTF-8")
    }

    func testSequenceRoundTrips() {
        let bytes = TerminalFilePreview.sequence(path: "/srv/a.md")
        XCTAssertEqual(bytes, Data("\u{1B}]6975;open;/srv/a.md\u{07}".utf8))
        // 影子终端报来的 payload 是 ESC ] 与 BEL 之间的那一段。
        XCTAssertEqual(TerminalFilePreview.path(fromOSC: bytes.dropFirst(2).dropLast()), "/srv/a.md")
    }

    func testThrottleDropsBurstsOfTheSamePath() {
        var throttle = TerminalFilePreviewThrottle()
        let t0 = Date()
        XCTAssertTrue(throttle.admits("/a.md", now: t0))
        XCTAssertFalse(throttle.admits("/a.md", now: t0.addingTimeInterval(0.2)))
        XCTAssertTrue(throttle.admits("/b.md", now: t0.addingTimeInterval(0.3)), "换了文件立刻认")
        XCTAssertTrue(throttle.admits("/a.md", now: t0.addingTimeInterval(0.4)))
        XCTAssertTrue(throttle.admits("/a.md", now: t0.addingTimeInterval(1.0)), "间隔够长再认")
    }

    func testPreviewKindByExtension() {
        XCTAssertEqual(TerminalFilePreviewKind.of(path: "/a/shot.PNG"), .image)
        XCTAssertEqual(TerminalFilePreviewKind.of(path: "/a/README.md"), .markdown)
        XCTAssertEqual(TerminalFilePreviewKind.of(path: "/a/main.go"), .text)
        XCTAssertEqual(TerminalFilePreviewKind.of(path: "/a/Makefile"), .text)
    }

    // MARK: ⌘ 点链接

    func testClassifiesLinks() {
        XCTAssertEqual(TerminalLink.classify("https://example.com/a?b=1"), .web(URL(string: "https://example.com/a?b=1")!))
        XCTAssertEqual(TerminalLink.classify("mailto:a@b.c"), .web(URL(string: "mailto:a@b.c")!))
        XCTAssertEqual(TerminalLink.classify("file://web-1/srv/a%20b.md"), .path("/srv/a b.md"), "OSC 8 的 file URL")
        XCTAssertEqual(TerminalLink.classify("/srv/app/plan.md:12"), .path("/srv/app/plan.md:12"))
        XCTAssertEqual(TerminalLink.classify("docs/plan.md"), .path("docs/plan.md"))
        XCTAssertEqual(TerminalLink.classify("ssh://host"), .unsupported, "只放行网页和邮件")
        XCTAssertEqual(TerminalLink.classify("tel:123"), .path("tel:123"), "不像网址的按路径处理，解析不出绝对路径就丢掉")
        XCTAssertNil(TerminalLinkPath.resolve("tel:123", workingDirectory: nil, home: nil))
        XCTAssertEqual(TerminalLink.classify("  "), .unsupported)
    }

    func testResolvesLinkedPaths() {
        let cwd = "/home/u/proj", home = "/home/u"
        func resolve(_ raw: String) -> String? { TerminalLinkPath.resolve(raw, workingDirectory: cwd, home: home) }
        XCTAssertEqual(resolve("/srv/a.md"), "/srv/a.md")
        XCTAssertEqual(resolve("/srv/a.md:12"), "/srv/a.md", "去掉 :行号")
        XCTAssertEqual(resolve("src/main.go:42:10"), "/home/u/proj/src/main.go", "去掉 :行号:列号")
        XCTAssertEqual(resolve("./docs/plan.md"), "/home/u/proj/docs/plan.md")
        XCTAssertEqual(resolve("../other/x.md"), "/home/u/other/x.md")
        XCTAssertEqual(resolve("~/notes.md"), "/home/u/notes.md")
        XCTAssertEqual(resolve("$HOME/notes.md"), "/home/u/notes.md")
        XCTAssertEqual(resolve("~"), "/home/u")
        XCTAssertNil(resolve("~other/notes.md"), "别人的家目录不猜")
        XCTAssertNil(resolve("$PWD/notes.md"))
        XCTAssertNil(TerminalLinkPath.resolve("docs/plan.md", workingDirectory: nil, home: home), "不知道当前目录")
        XCTAssertNil(TerminalLinkPath.resolve("~/a.md", workingDirectory: cwd, home: nil))

        XCTAssertEqual(TerminalLinkPath.need("/a"), .nothing)
        XCTAssertEqual(TerminalLinkPath.need("a/b.md"), .workingDirectory)
        XCTAssertEqual(TerminalLinkPath.need("~/b.md"), .home)
        XCTAssertEqual(TerminalLinkPath.path(fromOSC7: "file://web-1/home/u/my%20proj"), "/home/u/my proj")
        XCTAssertNil(TerminalLinkPath.path(fromOSC7: ""))
    }

    func testParsesForegroundDirectories() {
        let output = "Welcome to web-1\nuterm-cwd /home/u/proj\nuterm-home /home/u\n"
        XCTAssertEqual(RemoteForegroundDirectories(output: output),
                       RemoteForegroundDirectories(workingDirectory: "/home/u/proj", home: "/home/u"))
        XCTAssertEqual(RemoteForegroundDirectories(output: "uterm-cwd \nuterm-home /home/u\n"),
                       RemoteForegroundDirectories(workingDirectory: nil, home: "/home/u"), "读不到 cwd（别人的进程）")
        XCTAssertNil(RemoteForegroundDirectories(output: "sh: not found\n"))
        let command = RemoteForegroundDirectories.command(pid: 4242)
        XCTAssertTrue(command.hasPrefix("sh -c '"))
        XCTAssertTrue(command.contains("p=4242;"))
        XCTAssertTrue(command.contains("/proc/$p/cwd") && command.contains("lsof -a -p $p -d cwd"))
    }

    func testForegroundPIDIsTheForegroundGroupLeader() throws {
        let ps = """
        uterm-ps-begin 900
          100     1   100    -1 ?        sshd
          200   100   200   300 pts/0    -zsh
          300   200   300   300 pts/0    claude
          301   300   300   300 pts/0    node
          400   200   400   200 pts/0    gitstatusd
          900   100   900    -1 ?        sh
        uterm-ps-end
        """
        let table = try XCTUnwrap(RemoteProcessTable(output: ps))
        let shell = try XCTUnwrap(table.processes[200])
        XCTAssertEqual(table.foregroundPID(of: shell), 300, "前台是 claude")
        let idle = RemoteProcessTable.Process(pid: 200, ppid: 100, pgid: 200, tpgid: 200, tty: "pts/0", name: "zsh")
        XCTAssertEqual(table.foregroundPID(of: idle), 200, "停在提示符上就是 shell 自己")
    }

    func testLinkResolverPrefersTheReportedDirectoryAndFallsBackToTheBackend() async {
        let backend = DirectoriesBackend(RemoteForegroundDirectories(workingDirectory: "/srv/claude", home: "/home/u"))
        let fromOSC7 = await TerminalLinkResolver.absolutePath("docs/a.md", reportedDirectory: "file://h/srv/shell",
                                                               backend: backend)
        XCTAssertEqual(fromOSC7, "/srv/shell/docs/a.md")
        let probes = await backend.probes
        XCTAssertEqual(probes, 0, "OSC 7 报过就不跑命令")
        let probed = await TerminalLinkResolver.absolutePath("docs/a.md", reportedDirectory: "", backend: backend)
        XCTAssertEqual(probed, "/srv/claude/docs/a.md")
        let home = await TerminalLinkResolver.absolutePath("~/a.md", reportedDirectory: "file://h/srv", backend: backend)
        XCTAssertEqual(home, "/home/u/a.md")
        let none = await TerminalLinkResolver.absolutePath("docs/a.md", reportedDirectory: "", backend: nil)
        XCTAssertNil(none)
    }

    private actor DirectoriesBackend: TerminalBackend {
        nonisolated let outputItems = AsyncStream<TerminalOutputItem> { _ in }
        nonisolated let exitStream = AsyncStream<Void> { _ in }
        let directories: RemoteForegroundDirectories
        private(set) var probes = 0
        init(_ directories: RemoteForegroundDirectories) { self.directories = directories }
        func connect() async throws {}
        func write(_ data: Data) async {}
        func resize(cols: UInt16, rows: UInt16) async {}
        func close() async {}
        func foregroundDirectories() async -> RemoteForegroundDirectories? {
            probes += 1
            return directories
        }
    }

    func testSessionOpensWebLinksAndLeavesGhosttyFilesToGhostty() async {
        let session = TerminalSession()
        await session.connect(using: MockBackend())
        var requested: [String] = []
        session.onFilePreviewRequest = { requested.append($0) }
        XCTAssertFalse(session.openTerminalLink("/tmp/ghostty-scrollback.txt", kind: .text), "Ghostty 自己写的临时文件")
        XCTAssertTrue(session.openTerminalLink("/srv/app/plan.md:3", kind: .unknown))
        for _ in 0..<100 where requested.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(requested, ["/srv/app/plan.md"])
        XCTAssertTrue(session.openTerminalLink("ssh://host", kind: .osc8), "不放行的 scheme 也算处理过，不交给 Ghostty")
        await session.close()
    }

    // MARK: 会话里的接线

    func testSessionReportsRequestAndHidesTheSequence() async {
        let session = TerminalSession()
        await session.connect(using: MockBackend())
        var requested: [String] = []
        session.onFilePreviewRequest = { requested.append($0) }

        session.feedOutput(text: "wrote plan\r\n\u{1B}]6975;open;/srv/app/plan.md\u{07}done\r\n")

        XCTAssertEqual(requested, ["/srv/app/plan.md"])
        let screen = session.shadow.viewportText()
        XCTAssertFalse(screen.contains("6975"), "序列不显示：\(screen)")
        XCTAssertTrue(screen.contains("done"))
        await session.close()
    }

    func testSessionThrottlesRepeatsAndIgnoresInvalidPaths() async {
        let session = TerminalSession()
        await session.connect(using: MockBackend())
        var requested: [String] = []
        session.onFilePreviewRequest = { requested.append($0) }

        session.feedOutput(text: "\u{1B}]6975;open;/a.md\u{07}\u{1B}]6975;open;/a.md\u{07}")
        session.feedOutput(text: "\u{1B}]6975;open;relative.md\u{07}\u{1B}]6975;open;/b.png\u{07}")

        XCTAssertEqual(requested, ["/a.md", "/b.png"])
        await session.close()
    }

    func testTrackedRunMarkersStillReachTheirHandler() async {
        // 两种私有 OSC 共用影子终端的未知 OSC 出口：加了 6975 不能把 6973 挤掉。
        let session = TerminalSession()
        await session.connect(using: MockBackend())
        session.onFilePreviewRequest = { _ in XCTFail("命令跟踪标记不是预览请求") }
        let run = session.startTrackedRun("true")
        session.feedOutput(text: "\u{1B}]6973;S;\(run.id)\u{07}\u{1B}]6973;D;\(run.id);0\u{07}")
        XCTAssertEqual(session.trackedRun?.phase, .finished(0))
        await session.close()
    }

    // MARK: 预览区

    private func makePreview() -> (FilePreviewModel, MockSFTP) {
        let mock = MockSFTP()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("uTermTests-\(UUID().uuidString)")
        let model = FilePreviewModel(recentsStore: RecentFilesStore(rootDirectory: tmp, fileName: "r.json"),
                                     sftpProvider: { mock })
        return (model, mock)
    }

    func testRevealOpensAPreviewTabWithoutTakingFocus() async throws {
        let (model, mock) = makePreview()
        try await mock.write("/srv/plan.md", data: Data("# Plan".utf8))
        try await mock.write("/srv/next.md", data: Data("# Next".utf8))

        await model.reveal(path: "/srv/plan.md")
        XCTAssertEqual(model.activeBuffer?.remotePath, "/srv/plan.md")
        XCTAssertEqual(model.activeBuffer?.text, "# Plan")
        XCTAssertEqual(model.activeTabID.map(model.isTransientTab), true, "以预览（临时）标签打开")
        XCTAssertNil(model.editorFocusRequest, "键盘留在终端上")

        await model.reveal(path: "/srv/next.md")
        XCTAssertEqual(model.panes.allTabs.map(\.payload.remotePath), ["/srv/next.md"], "顶替上一个预览标签")
        XCTAssertNil(model.editorFocusRequest)
    }

    func testRevealReloadsAnOpenFileUnlessTheUserEditedIt() async throws {
        let (model, mock) = makePreview()
        try await mock.write("/srv/plan.md", data: Data("v1".utf8))
        try await mock.write("/srv/other.md", data: Data("x".utf8))
        await model.open(path: "/srv/plan.md", fileSize: nil, mtime: nil)
        await model.open(path: "/srv/other.md", fileSize: nil, mtime: nil)
        let focusBefore = model.editorFocusRequest
        let plan = try XCTUnwrap(model.buffers.first { $0.remotePath == "/srv/plan.md" })

        try await mock.write("/srv/plan.md", data: Data("v2".utf8))
        await model.reveal(path: "/srv/plan.md")
        XCTAssertEqual(model.activeBuffer?.remotePath, "/srv/plan.md", "切过去")
        XCTAssertEqual(plan.text, "v2", "程序刚改过：重读")
        XCTAssertEqual(model.editorFocusRequest, focusBefore, "不抢焦点")

        plan.text = "my edit"
        plan.isDirty = true
        try await mock.write("/srv/plan.md", data: Data("v3".utf8))
        await model.reveal(path: "/srv/plan.md")
        XCTAssertEqual(plan.text, "my edit", "用户改了没存：不盖掉")
    }

    func testWorkspaceOnlyAcceptsPreviewsWhenItHasAPreviewArea() async throws {
        let workspace = WorkspaceModel()
        let serverID = UUID()
        workspace.terminalRequestedPreview("/srv/plan.md", serverID: serverID)
        XCTAssertTrue(workspace.filePreviewModel.buffers.isEmpty, "纯终端窗口（默认）不接")

        workspace.acceptsTerminalFilePreviews = true
        workspace.terminalRequestedPreview("/srv/plan.md", serverID: serverID)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(workspace.filePreviewModel.buffers.isEmpty, "侧栏没连着这台主机：路径对不上，不接")
    }
}
