import XCTest
@testable import uTerm

final class ClaudeProjectPathTests: XCTestCase {
    func testEncodeReplacesEveryNonAlphanumericCharacter() {
        XCTAssertEqual(ClaudeProjectPath.encode("/home/user/demo"), "-home-user-demo")
        XCTAssertEqual(ClaudeProjectPath.encode("/home/user/my.app"), "-home-user-my-app")
        XCTAssertEqual(ClaudeProjectPath.encode("/Library/Application Support/x"), "-Library-Application-Support-x")
        XCTAssertEqual(ClaudeProjectPath.encode("/repo/.claude/worktrees/a_b"), "-repo--claude-worktrees-a-b")
        // 汉字一个字一个 `-`；码点在 BMP 之外的（emoji）按 UTF-16 是两个码元，两个 `-`。
        XCTAssertEqual(ClaudeProjectPath.encode("/下载/新建"), "------")
        XCTAssertEqual(ClaudeProjectPath.encode("/a😀"), "-a--")
    }

    func testNormalizedDropsDotsAndTrailingSlash() {
        XCTAssertEqual(ClaudeProjectPath.normalized("/a/./b//c/"), "/a/b/c")
        XCTAssertEqual(ClaudeProjectPath.normalized("/a/b/../c"), "/a/c")
        XCTAssertEqual(ClaudeProjectPath.normalized("/"), "/")
        XCTAssertNil(ClaudeProjectPath.normalized("relative/path"))
        XCTAssertNil(ClaudeProjectPath.normalized("~/x"))
    }

    func testLineageGoesFromSelfToTopWithoutRoot() {
        XCTAssertEqual(ClaudeProjectPath.lineage(of: "/a/b/c"), ["/a/b/c", "/a/b", "/a"])
        XCTAssertEqual(ClaudeProjectPath.lineage(of: "/"), [])
    }

    func testProjectContainingDirectoryUsesNearestAncestor() {
        let names: Set<String> = ["-home-user-demo", "-home-user"]
        let hit = ClaudeProjectPath.project(containing: "/home/user/demo/src/lib", among: names)
        XCTAssertEqual(hit?.name, "-home-user-demo")
        XCTAssertEqual(hit?.path, "/home/user/demo")
        XCTAssertEqual(ClaudeProjectPath.project(containing: "/home/user/other", among: names)?.path, "/home/user")
        XCTAssertNil(ClaudeProjectPath.project(containing: "/srv/app", among: names))
    }

    func testResumeDirectoryPicksCandidateWhoseEncodingMatches() {
        // 会话中途 cd 进了子目录：最后的 cwd 是子目录，项目目录是它的上级。
        XCTAssertEqual(ClaudeProjectPath.resumeDirectory(projectName: "-home-user-demo",
                                                         candidates: ["/home/user/demo/src", "/tmp"]),
                       "/home/user/demo")
        // 换过目录（relocatedCwd）：较新的对不上、较早的对得上。
        XCTAssertEqual(ClaudeProjectPath.resumeDirectory(projectName: "-repo--claude-worktrees-x",
                                                         candidates: ["/elsewhere", "/repo/.claude/worktrees/x"]),
                       "/repo/.claude/worktrees/x")
        XCTAssertNil(ClaudeProjectPath.resumeDirectory(projectName: "-home-user-demo", candidates: ["/srv"]))
    }

    func testDirectoryFromOSC7() {
        XCTAssertEqual(ClaudeProjectPath.directory(fromOSC7: "file://host.local/home/user/my%20dir"), "/home/user/my dir")
        XCTAssertEqual(ClaudeProjectPath.directory(fromOSC7: "file:///Users/a/b/"), "/Users/a/b")
        XCTAssertEqual(ClaudeProjectPath.directory(fromOSC7: "kitty-shell-cwd://h/srv/app"), "/srv/app")
        XCTAssertEqual(ClaudeProjectPath.directory(fromOSC7: "/plain/path"), "/plain/path")
        XCTAssertNil(ClaudeProjectPath.directory(fromOSC7: ""))
        XCTAssertNil(ClaudeProjectPath.directory(fromOSC7: "http://x/y"))
        XCTAssertNil(ClaudeProjectPath.directory(fromOSC7: "file://hostonly"))
    }

    func testProjectsRoot() {
        XCTAssertEqual(ClaudeProjectPath.projectsRoot(home: "/home/user"), "/home/user/.claude/projects")
        XCTAssertEqual(ClaudeProjectPath.projectsRoot(home: "/home/user/"), "/home/user/.claude/projects")
    }
}

final class ClaudeResumeCommandTests: XCTestCase {
    func testBuildsQuotedCommand() {
        XCTAssertEqual(ClaudeResumeCommand.make(sessionID: ClaudeFixture.sessionID, directory: "/home/user/demo"),
                       "cd -- '/home/user/demo' && claude --resume \(ClaudeFixture.sessionID)")
    }

    func testLowercasesSessionID() {
        let upper = ClaudeFixture.sessionID.uppercased()
        XCTAssertEqual(ClaudeResumeCommand.make(sessionID: upper, directory: "/a"),
                       "cd -- '/a' && claude --resume \(ClaudeFixture.sessionID)")
    }

    func testQuotesSingleQuotesAndShellMetacharacters() {
        XCTAssertEqual(ClaudeResumeCommand.make(sessionID: ClaudeFixture.sessionID, directory: "/a/it's $(x) `y`"),
                       #"cd -- '/a/it'\''s $(x) `y`' && claude --resume "# + ClaudeFixture.sessionID)
    }

    func testRejectsNonUUIDSessionIDs() {
        for bad in ["", "abc", "0b0e5f3a-1c2d-4e5f-8a9b-0c1d2e3f4a5b; rm -rf ~", "0b0e5f3a1c2d4e5f8a9b0c1d2e3f4a5b",
                    "zzzzzzzz-1c2d-4e5f-8a9b-0c1d2e3f4a5b", "0b0e5f3a-1c2d-4e5f-8a9b-0c1d2e3f4a5b\n"] {
            XCTAssertNil(ClaudeResumeCommand.make(sessionID: bad, directory: "/a"), bad)
        }
    }

    func testRejectsRelativeOrMultilineDirectories() {
        XCTAssertNil(ClaudeResumeCommand.make(sessionID: ClaudeFixture.sessionID, directory: "relative"))
        XCTAssertNil(ClaudeResumeCommand.make(sessionID: ClaudeFixture.sessionID, directory: "/a\nrm -rf ~"))
        XCTAssertNil(ClaudeResumeCommand.make(sessionID: ClaudeFixture.sessionID, directory: "/a\u{1B}]0;x\u{07}"))
    }
}
