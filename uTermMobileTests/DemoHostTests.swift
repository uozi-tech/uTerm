import XCTest
@testable import uTermMobile

/// 体验主机：模拟 shell、内存文件系统，以及终端与文件页共用同一份文件。
final class DemoShellTests: XCTestCase {
    private var fs: DemoFileSystem!
    private var shell: DemoShell!

    override func setUp() {
        super.setUp()
        fs = DemoFileSystem()
        shell = DemoShell(fs: fs)
    }

    func testStartsInHomeWithSeededFiles() {
        XCTAssertEqual(shell.run("pwd"), "/home/demo\n")
        let listing = shell.run("ls")
        for name in ["README.md", "logs", "notes.txt", "projects"] {
            XCTAssertTrue(listing.contains(name), "ls 里应有 \(name)：\(listing)")
        }
    }

    func testCdRelativeParentAndHome() {
        _ = shell.run("cd projects/website")
        XCTAssertEqual(shell.run("pwd"), "/home/demo/projects/website\n")
        _ = shell.run("cd ../..")
        XCTAssertEqual(shell.run("pwd"), "/home/demo\n")
        _ = shell.run("cd /tmp && cd")
        XCTAssertEqual(shell.run("pwd"), "/home/demo\n")
        XCTAssertEqual(shell.run("cd nowhere"), "bash: cd: nowhere: No such file or directory\n")
        XCTAssertEqual(shell.run("cd notes.txt"), "bash: cd: notes.txt: Not a directory\n")
    }

    func testRedirectAppendAndPipes() {
        _ = shell.run("echo hello > a.txt")
        _ = shell.run("echo world >> a.txt")
        XCTAssertEqual(shell.run("cat a.txt"), "hello\nworld\n")
        XCTAssertEqual(shell.run("cat a.txt | grep wor"), "world\n")
        XCTAssertEqual(shell.run("cat a.txt | wc -l"), "2\n")
        XCTAssertEqual(try fs.read("/home/demo/a.txt"), Data("hello\nworld\n".utf8))
    }

    func testFileOperations() {
        XCTAssertEqual(shell.run("mkdir -p x/y/z && touch x/y/f && ls x/y"), "f\nz\n")
        XCTAssertEqual(shell.run("rm x"), "rm: cannot remove 'x': Is a directory\n")
        _ = shell.run("cp -r x x2 && mv x2 x3")
        XCTAssertTrue(fs.isDirectory("/home/demo/x3/y/z"))
        XCTAssertNil(fs.node(at: "/home/demo/x2"))
        _ = shell.run("rm -r x x3")
        XCTAssertNil(fs.node(at: "/home/demo/x"))
        XCTAssertEqual(shell.run("rm -f missing; echo $?"), "0\n")
    }

    func testUnknownAndUnsupportedCommands() {
        XCTAssertEqual(shell.run("frobnicate"), "bash: frobnicate: command not found\n")
        XCTAssertEqual(shell.run("frobnicate; echo $?"), "bash: frobnicate: command not found\n127\n")
        XCTAssertTrue(shell.run("sudo ls").contains("sudoers"))
        XCTAssertFalse(shell.run("vim notes.txt").contains("command not found"))
    }

    func testAndOrShortCircuit() {
        XCTAssertEqual(shell.run("false && echo no || echo yes"), "yes\n")
        XCTAssertEqual(shell.run("true && echo yes"), "yes\n")
    }

    func testQuotingAndVariables() {
        XCTAssertEqual(shell.run("echo \"$HOME\" '$HOME' ~"), "/home/demo $HOME /home/demo\n")
        XCTAssertEqual(shell.run("echo 'a  b'"), "a  b\n")
        XCTAssertEqual(shell.run("echo *.md"), "README.md\n")
    }

    /// 文件页的搜索发的就是这一条（`RemoteFileSearch.buildFindCommand`），解析得出结果。
    func testFileSearchCommandFromFileBrowser() {
        let command = RemoteFileSearch.buildFindCommand(root: "/home/demo", pattern: "log")
        let hits = RemoteFileSearch.parseFindOutput(shell.run(command))
        XCTAssertEqual(Set(hits.map(\.path)), ["/home/demo/logs", "/home/demo/logs/app.log"])
        XCTAssertEqual(hits.first { $0.path == "/home/demo/logs" }?.isDirectory, true)
    }

    func testRecursiveChmodFromFileBrowser() {
        _ = shell.run(RemoteFileOperations.chmodRecursiveCommand(path: "/home/demo/projects", mode: 0o700,
                                                                     escapedNames: false))
        XCTAssertEqual(fs.node(at: "/home/demo/projects/api/main.go")?.mode, 0o700)
        XCTAssertEqual(DemoShell.parseMode("u+x", current: 0o644), 0o744)
        XCTAssertEqual(DemoShell.parseMode("go-r", current: 0o644), 0o600)
    }

    // MARK: - 交互

    func testInteractivePromptMarksAndEcho() {
        let start = shell.start()
        XCTAssertTrue(start.contains("\u{1b}]133;A\u{7}"))
        XCTAssertTrue(start.contains("\u{1b}]7;file://uterm-demo/home/demo\u{7}"))
        let typed = shell.receive("echo hi").output
        XCTAssertEqual(typed, "echo hi")
        let (out, exited) = shell.receive("\r")
        XCTAssertFalse(exited)
        XCTAssertTrue(out.contains("hi\r\n"))
        XCTAssertTrue(out.contains("\u{1b}]133;D;0\u{7}"))
        XCTAssertEqual(shell.history, ["echo hi"])
    }

    func testCRLFCountsAsOneEnter() {
        _ = shell.start()
        _ = shell.receive("echo a\r")
        _ = shell.receive("\n")
        XCTAssertEqual(shell.history, ["echo a"])
        _ = shell.receive("echo b\r\n")
        XCTAssertEqual(shell.history, ["echo a", "echo b"])
    }

    func testBackspaceHistoryAndCompletion() {
        _ = shell.start()
        _ = shell.receive("echx")
        _ = shell.receive("\u{7f}")
        _ = shell.receive("o x\r")
        XCTAssertEqual(shell.history, ["echo x"])
        XCTAssertTrue(shell.receive("\u{1b}[A").output.contains("echo x"))
        _ = shell.receive("\u{3}")
        XCTAssertTrue(shell.receive("ls pro\t").output.contains("ls projects/"))
    }

    func testExitEndsSession() {
        _ = shell.start()
        XCTAssertTrue(shell.receive("exit\r").exited)
        let other = DemoShell(fs: fs)
        _ = other.start()
        XCTAssertTrue(other.receive("\u{4}").exited)
    }
}

final class DemoHostBackendTests: XCTestCase {
    /// 终端里写的文件，文件页列得出来、下载得到；文件页传的文件，终端里 cat 得出来。
    func testTerminalAndFilesShareOneFileSystem() async throws {
        let fs = DemoFileSystem()
        let backend = DemoTerminalBackend(fileSystem: fs)
        let provider = DemoSFTPProvider(fileSystem: fs)
        try await backend.connect()
        await backend.write(Data("echo from-terminal > t.txt\r".utf8))

        let names = try await provider.list(path: "/home/demo").map(\.name)
        XCTAssertTrue(names.contains("t.txt"))
        let downloaded = try await provider.download(remotePath: "/home/demo/t.txt")
        XCTAssertEqual(String(decoding: downloaded, as: UTF8.self), "from-terminal\n")

        try await provider.upload(data: Data("up\n".utf8), toRemotePath: "/home/demo/u.txt")
        let shell = DemoShell(fs: fs)
        XCTAssertEqual(shell.run("cat u.txt"), "up\n")
    }

    func testProviderSemantics() async throws {
        let provider = DemoSFTPProvider(fileSystem: DemoFileSystem())
        let home = try await provider.realPath(".")
        XCTAssertEqual(home, "/home/demo")
        let entries = try await provider.list(path: home)
        XCTAssertEqual(entries.first { $0.name == "projects" }?.isDirectory, true)
        XCTAssertEqual(entries.first { $0.name == "notes.txt" }?.ownerName, "demo")

        try await provider.createFile("/home/demo/new.txt")
        do {
            try await provider.createFile("/home/demo/new.txt")
            XCTFail("已存在的文件不该被覆盖")
        } catch is SFTPFileExistsError {}

        try await provider.createDirectory("/home/demo/d")
        try await provider.rename("/home/demo/new.txt", to: "/home/demo/d/n.txt")
        let moved = try await provider.list(path: "/home/demo/d").map(\.name)
        XCTAssertEqual(moved, ["n.txt"])
        do {
            try await provider.removeDirectory("/home/demo/d")
            XCTFail("非空目录不该被删")
        } catch {}
        try await provider.removeFile("/home/demo/d/n.txt")
        try await provider.removeDirectory("/home/demo/d")
        try await provider.setPermissions(path: "/home/demo/notes.txt", mode: 0o600)
        let stat = try await provider.stat("/home/demo/notes.txt")
        XCTAssertEqual(stat.permissions.map { $0 & 0o777 }, 0o600)
    }

    func testUploadSizeLimit() async {
        let provider = DemoSFTPProvider(fileSystem: DemoFileSystem())
        do {
            try await provider.upload(data: Data(count: DemoHost.maxFileBytes + 1), toRemotePath: "/home/demo/big")
            XCTFail("超过上限应拒绝")
        } catch {
            XCTAssertTrue(error is DemoUploadTooLarge)
        }
    }

    func testExitFinishesBackend() async throws {
        let backend = DemoTerminalBackend(fileSystem: DemoFileSystem())
        try await backend.connect()
        var exits = backend.exitStream.makeAsyncIterator()
        await backend.write(Data("exit\r".utf8))
        let exited: Void? = await exits.next()
        XCTAssertNotNil(exited)
        let activity = await backend.foregroundActivity()
        XCTAssertEqual(activity, .idle)
    }
}
