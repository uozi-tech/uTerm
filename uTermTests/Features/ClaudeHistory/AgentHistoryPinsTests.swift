import XCTest
@testable import uTerm

/// 置顶：存储（顺序、按主机分开、持久化读回、上限、找不到的不删）、列表（「置顶」一组在最上、原组里去重、筛选、四种分组）、
/// 拖动的纯函数、行上工具名的规则。数据全是手写的假数据；偏好用一次性的 `UserDefaults(suiteName:)`，不碰标准偏好。
@MainActor
final class AgentHistoryPinsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_795_000_000)
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "AgentHistoryPinsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func key(_ id: String, _ tool: AgentHistoryTool = .claude) -> AgentHistoryPinKey {
        AgentHistoryPinKey(tool: tool, sessionID: id)
    }

    private func project(_ id: String, tool: AgentHistoryTool, directory: String? = nil) -> AgentHistoryProject {
        AgentHistoryProject(id: id, path: "/fake/\(tool.rawValue)/\(id)", modifiedAt: nil, directory: directory, tool: tool)
    }

    private func file(_ id: String, _ project: AgentHistoryProject, age: TimeInterval = 0) -> AgentHistorySessionFile {
        AgentHistorySessionFile(sessionID: id, project: project, path: project.path + "/\(id).jsonl", size: 100,
                                modifiedAt: now.addingTimeInterval(-age))
    }

    private func meta(_ directory: String?, listed: Bool = true) -> AgentHistorySessionMetadata {
        AgentHistorySessionMetadata(title: nil, isListed: listed, lastDirectory: directory, resumeDirectory: directory,
                                    gitBranch: "main", lastActivity: nil)
    }

    // MARK: 存储

    func testKeyAndHostEncoding() {
        XCTAssertEqual(key("0b7e-a1").stored, "claude:0b7e-a1")
        XCTAssertEqual(AgentHistoryPinKey(stored: "codex:x:1"), key("x:1", .codex), "会话 ID 里的冒号照留")
        XCTAssertNil(AgentHistoryPinKey(stored: "vim:1"), "认不出的工具")
        XCTAssertNil(AgentHistoryPinKey(stored: "claude:"))
        let id = UUID(uuidString: "6F1C2B0E-2D7A-4B5C-9E8F-0A1B2C3D4E5F")!
        XCTAssertEqual(AgentHistoryPinHost.server(id).stored, "server:6F1C2B0E-2D7A-4B5C-9E8F-0A1B2C3D4E5F")
        XCTAssertEqual(AgentHistoryPinHost.pairedMac(id).stored, "mac:6F1C2B0E-2D7A-4B5C-9E8F-0A1B2C3D4E5F")
        XCTAssertEqual(AgentHistoryPinHost.local.stored, "local")
    }

    func testPinsKeepOrderPerHostAndPersist() throws {
        let server = UUID()
        let pins = AgentHistoryPins(host: .server(server), defaults: defaults, now: { self.now })
        pins.pin(key("a"))
        pins.pin(key("b", .codex))
        pins.pin(key("a"))
        XCTAssertEqual(pins.keys, [key("a"), key("b", .codex)], "新置顶的排最后；已经置顶的不动")

        let local = AgentHistoryPins(host: .local, defaults: defaults)
        XCTAssertTrue(local.keys.isEmpty, "按主机分开")
        local.pin(key("a"))

        let reread = AgentHistoryPins(host: .server(server), defaults: defaults)
        XCTAssertEqual(reread.keys, [key("a"), key("b", .codex)], "读回来顺序不变")
        pins.unpin(key("a"))
        XCTAssertEqual(reread.keys, [key("b", .codex)], "同一台主机的另一个列表跟着变")
        XCTAssertEqual(AgentHistoryPins(host: .local, defaults: defaults).keys, [key("a")])

        // 只存「工具 + 会话 ID」和置顶时间，没有标题、路径。
        let data = try XCTUnwrap(defaults.data(forKey: DefaultsKey.agentHistoryPinnedSessions))
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("codex:b"))
        XCTAssertFalse(text.contains("/fake"))

        pins.unpin(key("b", .codex))
        local.unpin(key("a"))
        XCTAssertNil(defaults.object(forKey: DefaultsKey.agentHistoryPinnedSessions), "都取消了：键也删掉")
    }

    func testBrokenStorageCountsAsEmptyAndUnknownEntriesAreSkipped() {
        defaults.set(Data("not json".utf8), forKey: DefaultsKey.agentHistoryPinnedSessions)
        XCTAssertTrue(AgentHistoryPins(host: .local, defaults: defaults).keys.isEmpty)
        let json = #"{"local":[{"key":"vim:1","pinnedAt":0},{"key":"claude:a","pinnedAt":0}]}"#
        defaults.set(Data(json.utf8), forKey: DefaultsKey.agentHistoryPinnedSessions)
        XCTAssertEqual(AgentHistoryPins(host: .local, defaults: defaults).keys, [key("a")], "认不出的那一条跳过")
    }

    func testLimitDropsTheEarliestPinned() {
        var entries: [AgentHistoryPinEntry] = []
        for index in 0..<3 {
            entries = AgentHistoryPinning.appending(key("\(index)"), to: entries,
                                                    now: now.addingTimeInterval(Double(index)), limit: 3)
        }
        // 第 1 个拖到最前面：它不是最早置顶的。
        entries = AgentHistoryPinning.placing(key("1"), at: 0, visible: entries.map(\.key), in: entries, now: now, limit: 3)
        entries = AgentHistoryPinning.appending(key("3"), to: entries, now: now.addingTimeInterval(9), limit: 3)
        XCTAssertEqual(entries.map(\.key), [key("1"), key("2"), key("3")], "丢最早置顶的（0），不是排在最前的")
        XCTAssertEqual(AgentHistoryPinning.limit, 200)
    }

    // MARK: 列表

    func testResolvedSkipsMissingButDoesNotDelete() {
        let p = project("p", tool: .claude)
        let a = file("a", p), b = file("b", p, age: 5), hidden = file("h", p, age: 9)
        let metadata = [a.path: meta(nil), hidden.path: meta(nil, listed: false)]
        let pins = AgentHistoryPins(host: .local, defaults: defaults)
        for id in ["gone", "b", "a", "h"] { pins.pin(key(id)) }

        let shown = AgentHistoryPinning.resolved(pins.keys, in: [a, b, hidden], metadata: metadata)
        XCTAssertEqual(shown.map(\.sessionID), ["a"], "删掉的、还没读到信息的、不列出来的都不显示")
        XCTAssertEqual(pins.keys.count, 4, "但不从存储里删")
        XCTAssertEqual(AgentHistoryPins(host: .local, defaults: defaults).keys.count, 4)
    }

    func testPinnedGroupComesFirstAndLeavesItsOldGroup() {
        let shop = "/srv/shop", infra = "/srv/infra"
        let claude = project(ClaudeProjectPath.encode(shop), tool: .claude)
        let codex = project("r", tool: .codex, directory: infra)
        let files = [file("c1", claude, age: 1), file("x1", codex, age: 2), file("c2", claude, age: 3)]
        let metadata = Dictionary(uniqueKeysWithValues: files.map { ($0.path, meta($0.tool == .claude ? shop : infra)) })
        let pinned = AgentHistoryPinning.resolved([key("x1", .codex), key("c2")], in: files, metadata: metadata)

        for grouping in AgentHistoryGrouping.allCases {
            let groups = AgentHistoryListing.groups(files, by: grouping, metadata: metadata, pinned: pinned, now: now)
            XCTAssertEqual(groups.first?.kind, .pinned, "\(grouping)：「置顶」一组在最上")
            XCTAssertEqual(groups.first?.files.map(\.sessionID), ["x1", "c2"], "\(grouping)：按用户排的顺序")
            let rest = groups.dropFirst().flatMap(\.files).map(\.sessionID)
            XCTAssertEqual(rest, ["c1"], "\(grouping)：置顶的只在「置顶」里出现一次")
            XCTAssertTrue(groups.dropFirst().allSatisfy { !$0.files.isEmpty }, "\(grouping)：减到 0 的组不出")
            XCTAssertTrue(groups.allSatisfy { AgentHistoryListing.showsHeader($0, in: groups) },
                          "\(grouping)：有「置顶」时，不分组的那一组也画标题")
        }
        let project = AgentHistoryListing.groups(files, by: .project, metadata: metadata, pinned: pinned)
        XCTAssertEqual(project.map(\.id), [AgentHistoryGroup.pinnedID, "project:" + shop], "infra 那组只有置顶的那个：不出")
        XCTAssertEqual(AgentHistoryText.groupTitle(project[0]), AgentHistoryText.pinnedTitle)

        let none = AgentHistoryListing.groups(files, by: .none, metadata: metadata)
        XCTAssertEqual(none.map(\.kind), [.all], "没有置顶：没有这一组")
        XCTAssertFalse(AgentHistoryListing.showsHeader(none[0], in: none), "只有一组「不分组」：不画标题")
    }

    /// 被「显示」筛掉的工具，它的置顶会话也不显示；读到信息之前先把置顶的读出来。
    func testFilteredToolHidesItsPinsAndPinsAreReadFirst() async throws {
        let old = Date().addingTimeInterval(-86_400 * 90)
        var sessions = (0..<40).map { index in
            AgentHistoryFakeSource.Session(id: "c\(index)", projectID: "-srv-shop", resumeDirectory: "/srv/shop",
                                           title: "第 \(index) 个", modifiedAt: Date().addingTimeInterval(-Double(index) * 60))
        }
        sessions.append(.init(id: "c-old", projectID: "-srv-shop", resumeDirectory: "/srv/shop", title: "很早的那个",
                              modifiedAt: old))
        let claude = AgentHistoryFakeSource(tool: .claude, sessions: sessions)
        let codex = AgentHistoryFakeSource(tool: .codex, sessions: [
            .init(id: "x1", projectID: "2026-11-20", projectDirectory: "/srv/shop", resumeDirectory: "/srv/shop",
                  title: "Codex 的", modifiedAt: Date()),
        ])
        let history = AgentHistoryModel(source: AgentHistoryCompositeSource([claude, codex]), preferredDirectory: nil,
                                        followsCurrentProject: false)
        let pins = AgentHistoryPins(host: .local, defaults: defaults)
        pins.pin(key("c-old"))
        pins.pin(key("x1", .codex))
        history.pins = pins
        await history.start()
        for _ in 0..<200 where history.pinnedFiles.count < 2 { try await Task.sleep(for: .milliseconds(10)) }

        XCTAssertEqual(history.pinnedFiles.map(\.sessionID), ["c-old", "x1"],
                       "排在很后面的置顶会话不等翻页，先读出来")
        XCTAssertFalse(history.visibleFiles.contains { $0.sessionID == "c-old" }, "列表本身还没翻到它")

        history.setShownTools([.claude])
        XCTAssertEqual(history.pinnedFiles.map(\.sessionID), ["c-old"], "筛掉 Codex：它的置顶会话也不显示")
        XCTAssertEqual(pins.keys.count, 2, "存储不动")
    }

    // MARK: 拖动

    func testPlacingByVisiblePosition() {
        let entries = ["a", "hidden", "b", "c"].enumerated().map {
            AgentHistoryPinEntry(key: key($0.element), pinnedAt: now.addingTimeInterval(Double($0.offset)))
        }
        let visible = [key("a"), key("b"), key("c")]
        func order(_ moved: String, _ index: Int) -> [String] {
            AgentHistoryPinning.placing(key(moved), at: index, visible: visible, in: entries, now: now).map(\.key.sessionID)
        }
        XCTAssertEqual(order("c", 0), ["c", "a", "hidden", "b"], "组内拖到第一个")
        XCTAssertEqual(order("a", 2), ["hidden", "b", "c", "a"], "拖到最后：排在最后一个看得见的后面")
        XCTAssertEqual(order("a", 1), ["hidden", "b", "a", "c"], "看不见的那条相对顺序不变")
        XCTAssertEqual(order("new", 1), ["a", "hidden", "new", "b", "c"], "从下面拖进来：落在哪就排在哪")
        XCTAssertEqual(AgentHistoryPinning.placing(key("new"), at: 0, visible: [], in: [], now: now).map(\.key), [key("new")])

        let kept = AgentHistoryPinning.placing(key("b"), at: 0, visible: visible, in: entries, now: now.addingTimeInterval(99))
        XCTAssertEqual(kept.first { $0.key == key("b") }?.pinnedAt, entries[2].pinnedAt, "组内重排保留原来的置顶时间")
    }

    func testDropTargetByPosition() {
        // 置顶组的下沿在 100；别的两行中线在 40、70。
        XCTAssertEqual(AgentHistoryPinning.drop(at: 20, pinnedBottom: 100, otherRowMidYs: [40, 70], draggedIsPinned: false),
                       .pin(index: 0))
        XCTAssertEqual(AgentHistoryPinning.drop(at: 55, pinnedBottom: 100, otherRowMidYs: [40, 70], draggedIsPinned: true),
                       .pin(index: 1))
        XCTAssertEqual(AgentHistoryPinning.drop(at: 95, pinnedBottom: 100, otherRowMidYs: [40, 70], draggedIsPinned: true),
                       .pin(index: 2))
        XCTAssertEqual(AgentHistoryPinning.drop(at: 140, pinnedBottom: 100, otherRowMidYs: [40, 70], draggedIsPinned: true),
                       .unpin, "拖出「置顶」：取消")
        XCTAssertEqual(AgentHistoryPinning.drop(at: 140, pinnedBottom: 100, otherRowMidYs: [40, 70], draggedIsPinned: false),
                       .none, "没置顶的在下面拖来拖去：不动")
        XCTAssertEqual(AgentHistoryPinning.drop(at: 140, pinnedBottom: nil, otherRowMidYs: [], draggedIsPinned: false), .none)
    }

    func testDragModelOnlyAcceptsItsOwnDrag() {
        let p = project("p", tool: .claude)
        let pinned = [file("a", p), file("b", p)]
        let mine = AgentHistoryPinDragModel(), other = AgentHistoryPinDragModel()
        XCTAssertFalse(mine.ownsCurrentDrag)
        mine.begin(key("c"))
        XCTAssertTrue(mine.ownsCurrentDrag)
        other.begin(key("a"))
        XCTAssertFalse(mine.ownsCurrentDrag, "别的列表起的拖动不接（上一次没落下的也不算）")
        XCTAssertTrue(other.ownsCurrentDrag)

        other.frames = [.pinnedHeader: CGRect(x: 0, y: 0, width: 200, height: 26),
                        .pinnedRow(key("a")): CGRect(x: 0, y: 28, width: 200, height: 40),
                        .pinnedRow(key("b")): CGRect(x: 0, y: 70, width: 200, height: 40)]
        XCTAssertEqual(other.drop(at: CGPoint(x: 10, y: 100), pinned: pinned, pinnedCollapsed: false), .pin(index: 1),
                       "a 在组里往下拖到 b 的下半：排到 b 后面")
        other.setTarget(.pin(index: 1))
        XCTAssertTrue(other.indicatorAfter(key("b"), pinned: pinned), "插入线画在 b 的下沿")
        XCTAssertFalse(other.indicator(before: key("b"), pinned: pinned))
        XCTAssertEqual(other.drop(at: CGPoint(x: 10, y: 300), pinned: pinned, pinnedCollapsed: false), .unpin)
        XCTAssertEqual(other.drop(at: CGPoint(x: 10, y: 20), pinned: pinned, pinnedCollapsed: true), .pin(index: 1),
                       "组折起来了：落在组标题上排到最后")
        other.end()
        XCTAssertFalse(other.ownsCurrentDrag)
        XCTAssertFalse(other.isOver)
    }

    // MARK: 行上的工具名

    func testToolNameOnlyWhenTheGroupMixesTools() {
        let claude = project("p", tool: .claude), codex = project("q", tool: .codex, directory: "/srv/a")
        let a = file("a", claude), x = file("x", codex)
        XCTAssertTrue(AgentHistoryListing.mixesTools([a, x]))
        XCTAssertFalse(AgentHistoryListing.mixesTools([a, file("b", claude)]))
        XCTAssertFalse(AgentHistoryListing.mixesTools([]))

        let info = AgentHistorySessionMetadata(title: nil, isListed: true, lastDirectory: nil, resumeDirectory: nil,
                                               gitBranch: "main", lastActivity: nil)
        let plain = AgentHistoryText.sessionSubtitle(x, metadata: info, showsProject: false)
        let named = AgentHistoryText.sessionSubtitle(x, metadata: info, showsProject: false, showsTool: true)
        XCTAssertEqual(named, "Codex · " + plain, "工具名排最前，后面照旧（放不下时截掉的是尾巴上的分支）")
        XCTAssertFalse(plain.contains("Codex"))
        XCTAssertTrue(plain.hasSuffix("main"))
    }
}
