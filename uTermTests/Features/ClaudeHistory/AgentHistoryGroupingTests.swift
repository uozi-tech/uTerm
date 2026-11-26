import XCTest
@testable import uTerm

/// 分组、筛选、定位、偏好设置的编码（纯函数）。
@MainActor
final class AgentHistoryGroupingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_795_000_000)

    private func project(_ id: String, tool: AgentHistoryTool, directory: String? = nil) -> AgentHistoryProject {
        AgentHistoryProject(id: id, path: "/fake/\(tool.rawValue)/\(id)", modifiedAt: nil, directory: directory, tool: tool)
    }

    private func file(_ id: String, _ project: AgentHistoryProject, age: TimeInterval = 0) -> AgentHistorySessionFile {
        AgentHistorySessionFile(sessionID: id, project: project, path: project.path + "/\(id).jsonl", size: 100,
                                modifiedAt: now.addingTimeInterval(-age))
    }

    private func meta(resume: String?) -> AgentHistorySessionMetadata {
        AgentHistorySessionMetadata(title: nil, isListed: true, lastDirectory: resume, resumeDirectory: resume,
                                    gitBranch: nil, lastActivity: nil)
    }

    // MARK: 按项目

    func testProjectGroupingMergesToolsInSameDirectory() {
        let shop = "/home/dev/shop-api"
        let claude = project(ClaudeProjectPath.encode(shop), tool: .claude)
        let codex = project("rollouts", tool: .codex, directory: shop)
        let infra = project("infra", tool: .codex, directory: "/home/dev/infra")
        let files = [file("c1", claude, age: 10), file("x1", codex, age: 20), file("x2", infra, age: 30),
                     file("c2", claude, age: 40)]
        let metadata = [files[0].path: meta(resume: shop), files[3].path: meta(resume: shop + "/")]

        let groups = AgentHistoryListing.groups(files, by: .project, metadata: metadata)

        XCTAssertEqual(groups.map(\.id), ["project:" + shop, "project:/home/dev/infra"], "组按其中最新的会话排")
        XCTAssertEqual(groups[0].files.map(\.sessionID), ["c1", "x1", "c2"], "Claude 与 Codex 同一个目录并成一组，组内新的在前")
        XCTAssertEqual(groups[0].kind, .project(directory: shop, name: "shop-api"))
        XCTAssertEqual(AgentHistoryText.groupTitle(groups[0]), "shop-api")
        XCTAssertEqual(AgentHistoryText.groupHelp(groups[0]), shop, "悬停看全路径")
    }

    /// Claude Code 的会话信息还没读到（只有记录目录名）：别的工具里有换算出来正好是它的目录，就并进去。
    func testUnresolvedClaudeProjectJoinsMatchingDirectory() {
        let shop = "/home/dev/shop.api"
        let claude = project(ClaudeProjectPath.encode(shop), tool: .claude)
        let codex = project("r", tool: .codex, directory: shop)
        let files = [file("c1", claude, age: 5), file("x1", codex, age: 9)]

        let groups = AgentHistoryListing.groups(files, by: .project, metadata: [:])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].kind, .project(directory: shop, name: "shop.api"))
        XCTAssertEqual(groups[0].files.map(\.sessionID), ["c1", "x1"])
    }

    /// 两个目录换算出同一个名字（`/a/b-c` 与 `/a/b/c`）：对不上的 Claude 会话不硬并，单独成组，标题是目录名。
    func testAmbiguousClaudeProjectStaysOnItsOwn() {
        let encoded = ClaudeProjectPath.encode("/srv/b-c")
        XCTAssertEqual(encoded, ClaudeProjectPath.encode("/srv/b/c"))
        let claude = project(encoded, tool: .claude)
        let one = project("1", tool: .codex, directory: "/srv/b-c")
        let two = project("2", tool: .codex, directory: "/srv/b/c")
        let files = [file("c1", claude, age: 1), file("x1", one, age: 2), file("x2", two, age: 3)]

        let groups = AgentHistoryListing.groups(files, by: .project, metadata: [:])

        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups[0].kind, .project(directory: nil, name: encoded))
        XCTAssertEqual(AgentHistoryText.groupTitle(groups[0]), encoded)
        XCTAssertNotEqual(AgentHistoryText.groupHelp(groups[0]), encoded, "对不上路径的悬停说一句为什么")
        XCTAssertEqual(groups[1].kind, .project(directory: "/srv/b-c", name: "b-c"))
        XCTAssertEqual(groups[2].kind, .project(directory: "/srv/b/c", name: "c"))
    }

    /// 一种工具的项目目录名恰好长得像 Claude 的，也不拿来换算：只有 Claude Code 的目录名是换出来的。
    func testOnlyClaudeProjectsAreDecodedByName() {
        let codexUnknown = project(ClaudeProjectPath.encode("/home/dev/app"), tool: .codex)
        let codex = project("r", tool: .codex, directory: "/home/dev/app")
        let groups = AgentHistoryListing.groups([file("a", codexUnknown), file("b", codex, age: 1)], by: .project,
                                                metadata: [:])
        XCTAssertEqual(groups.count, 2)
    }

    func testSameFolderNameInDifferentParentsGetsDisambiguated() {
        let a = project("a", tool: .codex, directory: "/work/a/api")
        let b = project("b", tool: .codex, directory: "/work/b/api")
        let c = project("c", tool: .codex, directory: "/work/c/web")
        let groups = AgentHistoryListing.groups([file("1", a), file("2", b, age: 1), file("3", c, age: 2)], by: .project,
                                                metadata: [:])
        XCTAssertEqual(groups.map(AgentHistoryText.groupTitle), ["a/api", "b/api", "web"])
    }

    // MARK: 按日期

    func testDateBucketsAtBoundaries() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 10)))
        func at(_ days: Int, _ hour: Int, _ minute: Int = 0) throws -> Date {
            let day = try XCTUnwrap(calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now)))
            return day.addingTimeInterval(TimeInterval(hour * 3600 + minute * 60))
        }
        func bucket(_ date: Date) -> AgentHistoryDateBucket {
            AgentHistoryDateBucket.bucket(for: date, now: now, calendar: calendar)
        }
        XCTAssertEqual(bucket(try at(0, 0, 0)), .today, "今天零点")
        XCTAssertEqual(bucket(now.addingTimeInterval(3600)), .today, "比现在晚的（时钟不准）算今天")
        XCTAssertEqual(bucket(try at(1, 23, 59)), .yesterday)
        XCTAssertEqual(bucket(try at(1, 0, 0)), .yesterday)
        XCTAssertEqual(bucket(try at(2, 23, 59)), .pastWeek)
        XCTAssertEqual(bucket(try at(6, 0, 0)), .pastWeek)
        XCTAssertEqual(bucket(try at(7, 23, 59)), .pastMonth)
        XCTAssertEqual(bucket(try at(29, 0, 0)), .pastMonth)
        XCTAssertEqual(bucket(try at(30, 23, 59)), .older)
    }

    func testDateGroupingUsesGivenDateAndFixedOrder() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let p = project("p", tool: .claude, directory: "/p")
        let old = file("old", p, age: 86_400 * 40)
        let today = file("today", p, age: 60)
        let seenRecently = file("seen", p, age: 86_400 * 3)
        let groups = AgentHistoryListing.groups([today, seenRecently, old], by: .date, metadata: [:],
                                                date: { $0.sessionID == "seen" ? self.now : $0.modifiedAt },
                                                now: now, calendar: calendar)
        XCTAssertEqual(groups.map(\.kind), [.date(.today), .date(.older)], "空的档不出")
        XCTAssertEqual(groups[0].files.map(\.sessionID), ["today", "seen"], "看过、读到更新内容的会话按更新的时间归档")
    }

    // MARK: 按工具 / 不分组

    func testToolGroupingFollowsFixedToolOrder() {
        let x = project("x", tool: .codex, directory: "/x")
        let c = project("c", tool: .claude, directory: "/c")
        let groups = AgentHistoryListing.groups([file("1", x), file("2", c, age: 1), file("3", x, age: 2)], by: .tool,
                                                metadata: [:])
        XCTAssertEqual(groups.map(\.kind), [.tool(.claude), .tool(.codex)])
        XCTAssertEqual(groups[1].files.map(\.sessionID), ["1", "3"])
        XCTAssertEqual(AgentHistoryText.groupTitle(groups[1]), "Codex", "工具名不翻译")
    }

    func testNoGroupingIsOneGroupWithoutHeader() {
        let c = project("c", tool: .claude, directory: "/c")
        let groups = AgentHistoryListing.groups([file("1", c), file("2", c, age: 1)], by: .none, metadata: [:])
        XCTAssertEqual(groups.map(\.kind), [.all])
        XCTAssertEqual(groups[0].files.count, 2)
        XCTAssertTrue(AgentHistoryListing.groups([], by: .none, metadata: [:]).isEmpty)
    }

    // MARK: 定位

    func testRevealFindsNearestProjectGroup() {
        let shop = "/home/dev/shop-api"
        let groups = AgentHistoryListing.groups(
            [file("1", project("r", tool: .codex, directory: shop)),
             file("2", project("s", tool: .codex, directory: "/home/dev"), age: 1),
             file("3", project(ClaudeProjectPath.encode("/home/dev/blog"), tool: .claude), age: 2)],
            by: .project, metadata: [:])
        XCTAssertEqual(AgentHistoryListing.groupID(containing: shop + "/internal/auth", in: groups), "project:" + shop,
                       "子目录落到最近的上级那一组")
        XCTAssertEqual(AgentHistoryListing.groupID(containing: "/home/dev/other", in: groups), "project:/home/dev")
        XCTAssertEqual(AgentHistoryListing.groupID(containing: "/home/dev/blog/posts", in: groups),
                       groups[2].id, "Claude Code 对不上路径的那组按目录名换算对")
        XCTAssertNil(AgentHistoryListing.groupID(containing: "/srv", in: groups))
    }

    // MARK: 只看哪几种

    func testEffectiveToolsFallsBackToAll() {
        let both: [AgentHistoryTool] = [.claude, .codex]
        XCTAssertEqual(AgentHistoryListing.effectiveTools(shown: nil, available: both), [.claude, .codex])
        XCTAssertEqual(AgentHistoryListing.effectiveTools(shown: [.codex], available: both), [.codex])
        XCTAssertEqual(AgentHistoryListing.effectiveTools(shown: [.antigravity], available: both), [.claude, .codex],
                       "勾的这台上一种都没有：按全部")
        XCTAssertEqual(AgentHistoryListing.effectiveTools(shown: [.codex], available: [.claude]), [.claude],
                       "只有一种工具：不筛")
    }

    func testTogglingKeepsAtLeastOneAndCollapsesToAll() {
        let both: [AgentHistoryTool] = [.claude, .codex]
        XCTAssertEqual(AgentHistoryListing.toggling(.codex, shown: nil, available: both), [.claude])
        XCTAssertEqual(AgentHistoryListing.toggling(.claude, shown: [.claude], available: both), [.claude],
                       "不许一种都不勾")
        XCTAssertNil(AgentHistoryListing.toggling(.codex, shown: [.claude], available: both), "全勾上 = 全部")
    }

    // MARK: 偏好设置

    func testPreferenceCodec() {
        XCTAssertNil(AgentHistoryListPreferences.decodeTools(""))
        XCTAssertNil(AgentHistoryListPreferences.decodeTools("gone,also-gone"), "认不出的都跳过，一种都没有 = 全部")
        XCTAssertEqual(AgentHistoryListPreferences.decodeTools("codex,gone,claude"), [.claude, .codex])
        XCTAssertEqual(AgentHistoryListPreferences.encodeTools([.antigravity, .claude]), "claude,antigravity", "按固定的先后")
        XCTAssertEqual(AgentHistoryListPreferences.encodeTools(nil), "")
        XCTAssertEqual(AgentHistoryListPreferences.decodeGrouping(nil), .project)
        XCTAssertEqual(AgentHistoryListPreferences.decodeGrouping("weekday"), .project)
        XCTAssertEqual(AgentHistoryListPreferences.decodeGrouping("tool"), .tool)
        // 原始值进偏好设置，钉死。
        XCTAssertEqual(AgentHistoryGrouping.allCases.map(\.rawValue), ["project", "date", "tool", "none"])
    }

    /// 一次性的设置存储里读写（不碰正式的 UserDefaults）：存的只有枚举的原始值。
    func testPreferencesRoundTripThroughDefaults() throws {
        let suite = "agent-history-prefs-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(AgentHistoryGrouping.date.rawValue, forKey: DefaultsKey.agentHistoryGrouping)
        defaults.set(AgentHistoryListPreferences.encodeTools([.codex]), forKey: DefaultsKey.agentHistoryShownTools)

        XCTAssertEqual(AgentHistoryListPreferences.decodeGrouping(defaults.string(forKey: DefaultsKey.agentHistoryGrouping)),
                       .date)
        XCTAssertEqual(AgentHistoryListPreferences.decodeTools(defaults.string(forKey: DefaultsKey.agentHistoryShownTools) ?? ""),
                       [.codex])
        let stored = defaults.persistentDomain(forName: suite) ?? [:]
        XCTAssertEqual(Set(stored.keys), [DefaultsKey.agentHistoryGrouping, DefaultsKey.agentHistoryShownTools])
        XCTAssertEqual(stored.values.compactMap { $0 as? String }.sorted(), ["codex", "date"])
    }
}
