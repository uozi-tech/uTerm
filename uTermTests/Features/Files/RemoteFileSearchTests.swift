import XCTest
@testable import uTerm

final class RemoteFileSearchTests: XCTestCase {
    // resolveRoot
    func testResolveRootPlainQueryUsesHome() {
        let r = RemoteFileSearch.resolveRoot(query: "main", home: "/home/u")
        XCTAssertEqual(r.root, "/home/u"); XCTAssertEqual(r.pattern, "main")
    }
    func testResolveRootAbsolutePrefixSplitsDirAndLast() {
        let r = RemoteFileSearch.resolveRoot(query: "/var/lo", home: "/home/u")
        XCTAssertEqual(r.root, "/var"); XCTAssertEqual(r.pattern, "lo")
    }
    func testResolveRootAbsoluteTrailingSlashListsDir() {
        let r = RemoteFileSearch.resolveRoot(query: "/var/", home: "/home/u")
        XCTAssertEqual(r.root, "/var"); XCTAssertEqual(r.pattern, "")
    }
    func testResolveRootTildePrefixUsesHome() {
        let r = RemoteFileSearch.resolveRoot(query: "~/proj", home: "/home/u")
        XCTAssertEqual(r.root, "/home/u"); XCTAssertEqual(r.pattern, "proj")
    }
    func testResolveRootBareTildeUsesHomeEmptyPattern() {
        let r = RemoteFileSearch.resolveRoot(query: "~", home: "/home/u")
        XCTAssertEqual(r.root, "/home/u"); XCTAssertEqual(r.pattern, "")
    }
    func testResolveRootRootSlash() {
        let r = RemoteFileSearch.resolveRoot(query: "/etc", home: "/home/u")
        XCTAssertEqual(r.root, "/"); XCTAssertEqual(r.pattern, "etc")
    }

    // shSingleQuote
    func testShSingleQuoteWrapsAndEscapes() {
        XCTAssertEqual(RemoteFileSearch.shSingleQuote("a b"), "'a b'")
        XCTAssertEqual(RemoteFileSearch.shSingleQuote("a'b"), "'a'\\''b'")
    }

    // buildFindCommand
    func testBuildFindCommandStructure() {
        let cmd = RemoteFileSearch.buildFindCommand(root: "/home/u", pattern: "ma'in", maxDepth: 8, limit: 200)
        XCTAssertTrue(cmd.hasPrefix("sh -c '"), cmd)
        XCTAssertTrue(cmd.contains("find \"$a0\" -maxdepth 8"))
        XCTAssertTrue(cmd.contains("-iname \"$a1\""))
        XCTAssertTrue(cmd.contains("head -n 200"))
        XCTAssertTrue(cmd.contains("2>/dev/null"))
        XCTAssertFalse(cmd.contains("\n"))
        XCTAssertTrue(cmd.contains("a0='\\''/home/u'\\''"), "普通路径原样（外层单引号里的单引号写成 '\\''）")
    }

    /// 根目录与模式都按字节传进 sh 的变量：在本机真的跑一遍，模式里的引号、分号、命令替换都只是字面值，什么都不执行。
    func testBuildFindCommandNeutralizesShellInjection() throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("uterm-find-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        for pattern in ["x'; touch \(marker.path); '", "$(touch \(marker.path))", "`touch \(marker.path)`"] {
            let cmd = RemoteFileSearch.buildFindCommand(root: "/nonexistent-uterm", pattern: pattern)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", cmd]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "模式被当成命令执行了：\(pattern)")
        }
    }

    /// 会还原转义的 provider（SSH）：find 打出来的原样文字换成 `RemoteName` 写法再交回，名字里本来就有的 U+2060
    /// 不会被当成转义的收尾。
    func testSearchHitsFromAnEscapingProviderAreInDisplayForm() async throws {
        let literal = "/home/u/a\u{FFFD}B2\u{2060}.txt"
        let ssh = MockSFTP(escapesRawNames: true)
        await ssh.setExecOutput("f\t\(literal)\n")
        let hits = try await RemoteFileSearch.search(query: "a", home: "/home/u", provider: ssh)
        XCTAssertEqual(RemoteName.bytes(hits[0].path), Array(literal.utf8), "还原出来的是服务器上原样的字节")

        let mac = MockSFTP()
        await mac.setExecOutput("f\t\(literal)\n")
        let macHits = try await RemoteFileSearch.search(query: "a", home: "/home/u", provider: mac)
        XCTAssertEqual(macHits.first?.path, literal, "不还原转义的 provider 原样给")
    }

    // parseFindOutput
    func testParseFindOutputTypesAndPaths() {
        let text = "d\t/home/u/proj\nf\t/home/u/a.txt\nl\t/home/u/link\n\n"
        let hits = RemoteFileSearch.parseFindOutput(text)
        XCTAssertEqual(hits, [
            RemoteHit(path: "/home/u/proj", isDirectory: true),
            RemoteHit(path: "/home/u/a.txt", isDirectory: false),
            RemoteHit(path: "/home/u/link", isDirectory: false),
        ])
    }
    func testParseFindOutputNoTabFallbackTreatsAsFile() {
        let hits = RemoteFileSearch.parseFindOutput("/home/u/x.txt\n")
        XCTAssertEqual(hits, [RemoteHit(path: "/home/u/x.txt", isDirectory: false)])
    }
    func testParseFindOutputHandlesCRLF() {
        let hits = RemoteFileSearch.parseFindOutput("d\t/a/proj\r\nf\t/a/b.txt\r\n")
        XCTAssertEqual(hits, [
            RemoteHit(path: "/a/proj", isDirectory: true),
            RemoteHit(path: "/a/b.txt", isDirectory: false),
        ])
    }

    // search (async, wired through MockSFTP.exec)
    func testSearchRunsFindAndParsesOutput() async throws {
        let mock = MockSFTP()
        await mock.setExecOutput("d\t/home/u/proj\nf\t/home/u/proj/main.go\n")
        let hits = try await RemoteFileSearch.search(query: "proj", home: "/home/u", provider: mock)
        XCTAssertEqual(hits, [
            RemoteHit(path: "/home/u/proj", isDirectory: true),
            RemoteHit(path: "/home/u/proj/main.go", isDirectory: false),
        ])
    }

    func testSearchEmptyOutputYieldsNoHits() async throws {
        let mock = MockSFTP()
        await mock.setExecOutput("")
        let hits = try await RemoteFileSearch.search(query: "nope", home: "/home/u", provider: mock)
        XCTAssertTrue(hits.isEmpty)
    }
}
