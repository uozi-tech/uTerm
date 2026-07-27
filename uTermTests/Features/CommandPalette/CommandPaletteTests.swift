import XCTest
@testable import uTerm

@MainActor
final class CommandPaletteTests: XCTestCase {

    // MARK: helpers

    private func item(_ id: String, _ kind: CommandPaletteKind,
                      title: String, detail: String = "",
                      run: @escaping @MainActor () -> Void = {}) -> CommandPaletteItem {
        CommandPaletteItem(id: id, kind: kind, title: title, detail: detail,
                           hint: "", group: nil, run: run)
    }

    private func sample() -> [CommandPaletteItem] {
        [
            item("h1", .host, title: "demo-server", detail: "root@203.0.113.10"),
            item("c1", .command, title: "新建主机…", detail: "创建一台新服务器"),
            item("f1", .file, title: "main.go", detail: "~/src/main.go"),
            item("s1", .setting, title: "设置 · 终端", detail: "字体、颜色、行距"),
        ]
    }

    // MARK: filter

    func testFilterEmptyQueryReturnsAll() {
        XCTAssertEqual(filterCommandPalette(sample(), query: "").count, 4)
        XCTAssertEqual(filterCommandPalette(sample(), query: "   ").count, 4)
    }

    func testFilterMatchesTitleCaseInsensitive() {
        let r = filterCommandPalette(sample(), query: "MAIN")
        XCTAssertEqual(r.map(\.id), ["f1"])
    }

    func testFilterMatchesDetail() {
        let r = filterCommandPalette(sample(), query: "47.113")
        XCTAssertEqual(r.map(\.id), ["h1"])
    }

    func testFilterMatchesKindRawValue() {
        let r = filterCommandPalette(sample(), query: "setting")
        XCTAssertEqual(r.map(\.id), ["s1"])
    }

    func testFilterNoMatchReturnsEmpty() {
        XCTAssertTrue(filterCommandPalette(sample(), query: "zzz").isEmpty)
    }

    // MARK: group

    func testGroupOrdersHostCommandFileSettingAndDropsEmpty() {
        // 打乱输入顺序
        let scrambled = [
            item("s1", .setting, title: "s"),
            item("f1", .file, title: "f"),
            item("h1", .host, title: "h"),
            item("c1", .command, title: "c"),
        ]
        let sections = groupCommandPalette(scrambled)
        XCTAssertEqual(sections.map(\.kind), [.host, .command, .file, .setting])
        XCTAssertEqual(sections.map(\.label), ["主机", "命令", "文件", "设置"])
    }

    func testGroupOnlyIncludesPresentKinds() {
        let only = [item("h1", .host, title: "h"), item("h2", .host, title: "h2")]
        let sections = groupCommandPalette(only)
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].items.map(\.id), ["h1", "h2"])
    }

    func testFilterEmptyInputArrayReturnsEmpty() {
        XCTAssertTrue(filterCommandPalette([], query: "").isEmpty)
        XCTAssertTrue(filterCommandPalette([], query: "host").isEmpty)
    }

    func testFilterThenGroupDropsEliminatedKind() {
        // 过滤掉所有非 host 项后，分组结果不应再出现 命令/文件/设置 组。
        let filtered = filterCommandPalette(sample(), query: "uozi")
        let sections = groupCommandPalette(filtered)
        XCTAssertEqual(sections.map(\.kind), [.host])
        XCTAssertEqual(sections.first?.items.map(\.id), ["h1"])
    }

    // MARK: model

    private func model(with items: [CommandPaletteItem]) -> CommandPaletteModel {
        let m = CommandPaletteModel()
        m.open(items: items)
        return m
    }

    func testOpenResetsQueryAndSelectionAndPresents() {
        let m = model(with: sample())
        XCTAssertTrue(m.isPresented)
        XCTAssertEqual(m.query, "")
        XCTAssertEqual(m.selectedIndex, 0)
        XCTAssertEqual(m.results.count, 4)
    }

    func testMoveSelectionClampsBounds() {
        let m = model(with: sample())
        m.moveSelection(by: -1)               // 已在顶，不越界
        XCTAssertEqual(m.selectedIndex, 0)
        m.moveSelection(by: 99)               // 越过底，clamp 到末项
        XCTAssertEqual(m.selectedIndex, m.results.count - 1)
    }

    func testResultsFollowGroupedDisplayOrder() {
        // 打乱顺序输入，results 应跟分组显示顺序（host, command, file, setting）
        let m = model(with: [
            item("s1", .setting, title: "s"),
            item("h1", .host, title: "h"),
            item("c1", .command, title: "c"),
            item("f1", .file, title: "f"),
        ])
        XCTAssertEqual(m.results.map(\.id), ["h1", "c1", "f1", "s1"])
    }

    func testSetQueryResetsSelection() {
        let m = model(with: sample())
        m.moveSelection(by: 2)
        XCTAssertEqual(m.selectedIndex, 2)
        m.setQuery("x")
        XCTAssertEqual(m.selectedIndex, 0)
    }

    func testHoverSelectsMatchingIndex() {
        let m = model(with: sample())          // results: h1,c1,f1,s1
        m.hover(itemID: "f1")
        XCTAssertEqual(m.selectedIndex, 2)
        XCTAssertEqual(m.selectedItemID, "f1")
    }

    func testHoverUnknownIDIsNoOp() {
        let m = model(with: sample())
        m.moveSelection(by: 1)                 // selectedIndex = 1
        m.hover(itemID: "does-not-exist")
        XCTAssertEqual(m.selectedIndex, 1)     // unchanged
    }

    func testExecuteRunsSelectedItemAndCloses() {
        var fired: [String] = []
        let m = model(with: [
            item("a", .host, title: "alpha", run: { fired.append("a") }),
            item("b", .host, title: "beta", run: { fired.append("b") }),
        ])
        m.moveSelection(by: 1)                 // 选中 beta
        m.executeSelected()
        XCTAssertEqual(fired, ["b"])
        XCTAssertFalse(m.isPresented)
    }

    func testExecuteWithEmptyResultsDoesNothing() {
        var fired = 0
        let m = model(with: [item("a", .host, title: "alpha", run: { fired += 1 })])
        m.setQuery("zzz")                      // 过滤到空
        XCTAssertTrue(m.results.isEmpty)
        m.executeSelected()                    // 不崩、不触发
        XCTAssertEqual(fired, 0)
    }

    // MARK: 去重纯函数
    func testDedupeByIDKeepsFirstOccurrence() {
        let items = [
            item("file:/a", .file, title: "first"),
            item("file:/a", .file, title: "dup"),
            item("h1", .host, title: "h"),
        ]
        let r = dedupeCommandPaletteByID(items)
        XCTAssertEqual(r.map(\.id), ["file:/a", "h1"])
        XCTAssertEqual(r.first?.title, "first")
    }

    // MARK: 异步搜索
    private func fileItem(_ q: String) -> CommandPaletteItem {
        item("file:/x/\(q)", .file, title: "\(q)")
    }

    func testSearchProviderTriggersAtTwoCharsAndMergesIntoResults() async {
        let m = CommandPaletteModel()
        m.searchDebounceNanos = 0
        m.searchProvider = { [self] q in [fileItem(q)] }
        m.open(items: [item("h1", .host, title: "host")])
        m.setQuery("ab")
        await m.waitForSearch()
        XCTAssertTrue(m.results.contains { $0.id == "file:/x/ab" })
    }

    func testSearchProviderNotTriggeredBelowTwoChars() async {
        let m = CommandPaletteModel()
        m.searchDebounceNanos = 0
        var calls = 0
        m.searchProvider = { _ in calls += 1; return [] }
        m.open(items: [])
        m.setQuery("a")
        await m.waitForSearch()    // searchTask 为 nil → 立即返回
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(m.dynamicItems.isEmpty)
    }

    func testDynamicAndStaticDedupeBySameID() async {
        let m = CommandPaletteModel()
        m.searchDebounceNanos = 0
        m.searchProvider = { [self] q in [fileItem(q)] }
        m.open(items: [item("file:/x/ab", .file, title: "recent-ab")])
        m.setQuery("ab")
        await m.waitForSearch()
        XCTAssertEqual(m.results.filter { $0.id == "file:/x/ab" }.count, 1)
        XCTAssertEqual(m.results.first { $0.id == "file:/x/ab" }?.title, "recent-ab")  // 静态在前胜出
    }

    func testRapidSetQueryCancelsPriorSearch() async {
        let m = CommandPaletteModel()
        m.searchDebounceNanos = 20_000_000   // 20ms：第一发在 sleep 中被取消
        var queriesRun: [String] = []
        m.searchProvider = { [self] q in queriesRun.append(q); return [fileItem(q)] }
        m.open(items: [])
        m.setQuery("aa")
        m.setQuery("bb")     // 同步取消 aa 的 task
        await m.waitForSearch()
        XCTAssertEqual(queriesRun, ["bb"])
        XCTAssertTrue(m.results.contains { $0.id == "file:/x/bb" })
    }

    func testCloseClearsDynamicState() async {
        let m = CommandPaletteModel()
        m.searchDebounceNanos = 0
        m.searchProvider = { [self] q in [fileItem(q)] }
        m.open(items: [])
        m.setQuery("ab")
        await m.waitForSearch()
        XCTAssertFalse(m.dynamicItems.isEmpty)
        m.close()
        XCTAssertTrue(m.dynamicItems.isEmpty)
        XCTAssertFalse(m.isSearching)
    }

    // MARK: interaction

    func testMouseSelectionDoesNotDrivePaletteScrolling() throws {
        let source = try String(contentsOf: repoRoot.appendingPathComponent(
            "uTerm/DesignKitExtras/UDCommandPalette.swift"
        ), encoding: .utf8)

        XCTAssertFalse(source.contains(".onChange(of: selectedID)"))
        XCTAssertTrue(source.contains(".onChange(of: keyboardScrollRequest)"))
        XCTAssertTrue(source.contains("proxy.scrollTo(request.targetID"))
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
