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
