import XCTest
@testable import uTerm

/// 列表缓存落盘：App 重开之后第一次打开侧栏先出上次列到的（实机反馈：首次打开慢、行一批批进来顺序跳）。
@MainActor
final class AgentHistoryListCachePersistenceTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("list-cache-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func entry(title: String, rows: Int = 3) -> AgentHistoryListCache.Entry {
        let project = AgentHistoryProject(id: "-p", path: "/h/.claude/projects/-p", modifiedAt: Date(timeIntervalSince1970: 100),
                                          directory: "/p", tool: .claude)
        let file = AgentHistorySessionFile(sessionID: "s1", project: project, path: "/h/.claude/projects/-p/s1.jsonl",
                                           size: 42, modifiedAt: Date(timeIntervalSince1970: 200))
        let metadata = AgentHistorySessionMetadata(
            title: title, isListed: true, lastDirectory: "/p", resumeDirectory: "/p", gitBranch: "main",
            lastActivity: Date(timeIntervalSince1970: 200),
            rateLimits: AgentRateLimits(primary: .init(usedPercent: 12, windowMinutes: 300, resetsAt: nil),
                                        secondary: nil, plan: "pro"))
        return .init(projects: [project], availableTools: [.claude, .codex], listedFiles: [file],
                     metadata: [file.path: metadata], metadataKeys: [file.path: file.cacheKey], shownRows: rows)
    }

    func testStoredListSurvivesARelaunch() async throws {
        let cache = AgentHistoryListCache(directory: directory)
        cache.store("host|claude|codex|/h", entry(title: "修侧栏"))
        await cache.flush()

        // App 重开：内存里没有，从盘上读回来。
        let relaunched = AgentHistoryListCache(directory: directory)
        XCTAssertNil(relaunched.entry("host|claude|codex|/h"))
        let read = await relaunched.persistedEntry("host|claude|codex|/h")
        let restored = try XCTUnwrap(read)
        XCTAssertEqual(restored.listedFiles.map(\.path), ["/h/.claude/projects/-p/s1.jsonl"])
        XCTAssertEqual(restored.metadata.values.first?.title, "修侧栏")
        XCTAssertEqual(restored.metadata.values.first?.rateLimits?.windows.first?.usedPercent, 12)
        XCTAssertEqual(restored.availableTools, [.claude, .codex])
        XCTAssertEqual(restored.shownRows, 3)
        // 之后内存里就有了。
        XCTAssertNotNil(relaunched.entry("host|claude|codex|/h"))
        // 文件名不带主机名。
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(names.contains { $0.contains("host") })
    }

    func testOtherKeyAndMemoryOnlyFindNothing() async {
        let cache = AgentHistoryListCache(directory: directory)
        cache.store("a", entry(title: "x"))
        await cache.flush()
        let relaunched = AgentHistoryListCache(directory: directory)
        let other = await relaunched.persistedEntry("b")
        XCTAssertNil(other)

        let memoryOnly = AgentHistoryListCache(directory: nil)
        memoryOnly.store("a", entry(title: "x"))
        await memoryOnly.flush()
        let fresh = await AgentHistoryListCache(directory: nil).persistedEntry("a")
        XCTAssertNil(fresh)
    }

    /// 盘上只留最近用过的 `capacity` 份。
    func testDiskKeepsOnlyTheMostRecentHosts() async throws {
        let cache = AgentHistoryListCache(directory: directory)
        for index in 0...AgentHistoryListCache.capacity {
            cache.store("host-\(index)", entry(title: "\(index)"))
            await cache.flush()
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".json") }
        XCTAssertEqual(names.count, AgentHistoryListCache.capacity)
        let relaunched = AgentHistoryListCache(directory: directory)
        let oldest = await relaunched.persistedEntry("host-0")
        XCTAssertNil(oldest)
        let newest = await relaunched.persistedEntry("host-\(AgentHistoryListCache.capacity)")
        XCTAssertNotNil(newest)
    }

    /// 读不出来（旧格式、坏文件）当没有，不崩。
    func testUnreadableFileCountsAsNothing() async throws {
        let cache = AgentHistoryListCache(directory: directory)
        cache.store("k", entry(title: "x"))
        await cache.flush()
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        try Data("{\"version\":0}".utf8).write(to: file)
        let restored = await AgentHistoryListCache(directory: directory).persistedEntry("k")
        XCTAssertNil(restored)
    }
}

/// 打开侧栏的第一帧就是上次完整的列表（实机：先出一部分，扫描时一行行冒出来）。
@MainActor
final class AgentHistoryListFirstFrameTests: XCTestCase {
    private func source() -> AgentHistoryFakeSource {
        AgentHistoryFakeSource(tool: .claude, sessions: (0..<12).map { index in
            .init(id: "s\(index)", projectID: "-p\(index % 3)", resumeDirectory: "/p", title: "会话 \(index)",
                  modifiedAt: Date(timeIntervalSince1970: 1_000 + Double(index) * 60))
        })
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func testReopenShowsTheWholeLastListBeforeAnyRelisting() async throws {
        let key = "first-frame-\(UUID().uuidString)"
        let first = AgentHistoryModel(source: source(), preferredDirectory: nil, cacheKey: key)
        await first.start()
        await waitUntil { first.visibleFiles.count == 12 }
        let shown = first.visibleFiles.map(\.path)
        XCTAssertEqual(shown.count, 12)

        // 再开一次：交给界面之前同步换上缓存，这时还一次都没列过，行已经是全部 12 行、同样的顺序。
        let second = AgentHistoryModel(source: source(), preferredDirectory: nil, cacheKey: key)
        XCTAssertTrue(second.applyCachedListing())
        XCTAssertEqual(second.phase, .ready)
        XCTAssertEqual(second.visibleFiles.map(\.path), shown)

        // 后台重列（数据没变）：一行不多、一行不少、顺序不变。
        await second.start()
        await waitUntil { second.visibleFiles.map(\.path) == shown }
        XCTAssertEqual(second.visibleFiles.map(\.path), shown)
    }

    /// 写盘攒一秒：退到后台时当场写，下次 App 重开读到的是完整的那份，不是一秒前那份。
    func testBackgroundFlushWritesTheLatestListing() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("list-flush-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = AgentHistoryListCache(directory: directory)
        let project = AgentHistoryProject(id: "-p", path: "/p", modifiedAt: nil, directory: "/p", tool: .claude)
        func entry(_ rows: Int) -> AgentHistoryListCache.Entry {
            let files = (0..<rows).map {
                AgentHistorySessionFile(sessionID: "s\($0)", project: project, path: "/p/s\($0).jsonl", size: 1,
                                        modifiedAt: Date(timeIntervalSince1970: Double($0)))
            }
            return .init(projects: [project], availableTools: [.claude], listedFiles: files, metadata: [:],
                         metadataKeys: [:], shownRows: rows)
        }
        cache.store("k", entry(3))
        await cache.flush()
        cache.store("k", entry(9))
        cache.flushNow()
        let restored = await AgentHistoryListCache(directory: directory).persistedEntry("k")
        XCTAssertEqual(restored?.listedFiles.count, 9)
    }
}
