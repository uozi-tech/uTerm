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
    func testBuildFindCommandStructureAndEscaping() {
        let cmd = RemoteFileSearch.buildFindCommand(root: "/home/u", pattern: "ma'in", maxDepth: 8, limit: 200)
        XCTAssertTrue(cmd.contains("find '/home/u'"))
        XCTAssertTrue(cmd.contains("-maxdepth 8"))
        XCTAssertTrue(cmd.contains("-iname '*ma'\\''in*'"))
        XCTAssertTrue(cmd.contains("head -n 200"))
        XCTAssertTrue(cmd.contains("2>/dev/null"))
        XCTAssertFalse(cmd.contains("\n"))
    }
    func testBuildFindCommandEmptyPatternUsesStar() {
        let cmd = RemoteFileSearch.buildFindCommand(root: "/var", pattern: "")
        XCTAssertTrue(cmd.contains("-iname '*'"))
    }
    func testBuildFindCommandNeutralizesShellInjection() {
        let cmd = RemoteFileSearch.buildFindCommand(root: "/home/u", pattern: "x; rm -rf /")
        XCTAssertTrue(cmd.contains("'*x; rm -rf /*'"))
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
