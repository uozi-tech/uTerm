import XCTest
@testable import uTerm

/// `CommandPaletteModel` 把 `sections` / `results` 从计算属性改成「一次求值存
/// 下来」之后的**契约闸门**。
///
/// 计算属性本来天然一致；改成存储之后，一致性变成了一条要守的约束 ——
/// **每一条会改 `query` / `allItems` / `dynamicItems` 的路径都必须走
/// `rebuild()`**。漏一条就会出现「面板里还显示上一次的候选」这种脏状态，
/// 而且不会崩、只会显示错。所以这里逐条路径钉。
///
/// 键盘导航 / 执行 / 去重 / 精确匹配排序的行为闸门在 `CommandPaletteTests`，
/// 那 31 条一条没动、全绿。
@MainActor
final class CommandPaletteDerivationContractTests: XCTestCase {

    private func item(_ id: String, _ kind: CommandPaletteKind,
                      _ title: String, _ detail: String = "") -> CommandPaletteItem {
        CommandPaletteItem(id: id, kind: kind, title: title, detail: detail, hint: "↵") {}
    }

    private func assertConsistent(_ m: CommandPaletteModel,
                                  _ message: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(m.results.map(\.id), m.sections.flatMap(\.items).map(\.id),
                       "results 必须与 sections 同一次求值的产物（\(message)）",
                       file: file, line: line)
        let expectedSections = groupCommandPaletteByMatchPriority(
            dedupeCommandPaletteByID(
                filterCommandPalette(m.allItems, query: m.query) + m.dynamicItems),
            query: m.query)
        XCTAssertEqual(m.sections.map(\.id), expectedSections.map(\.id),
                       "sections 必须与「现算一遍」的结果一致（\(message)）",
                       file: file, line: line)
        XCTAssertEqual(m.sections.flatMap(\.items).map(\.id),
                       expectedSections.flatMap(\.items).map(\.id),
                       "sections 的条目也必须一致（\(message)）", file: file, line: line)
    }

    private var sample: [CommandPaletteItem] {
        [item("h1", .host, "web-01", "deploy@10.0.0.1"),
         item("h2", .host, "web-02", "deploy@10.0.0.2"),
         item("c1", .command, "新建服务器", "添加一台主机"),
         item("f1", .file, "/etc/nginx/nginx.conf", "web-01"),
         item("s1", .setting, "设置 · 通用", "外观、启动、语言、更新")]
    }

    /// 五条会改候选集的路径逐条走一遍。
    func testEveryMutationPathKeepsSectionsAndResultsInSync() {
        let m = CommandPaletteModel()
        m.searchDebounceNanos = 0

        // ① 初始（还没 open）
        assertConsistent(m, "初始态")
        XCTAssertTrue(m.sections.isEmpty)

        // ② open：query 归零 → 空 query 不出建议
        m.open(items: sample)
        assertConsistent(m, "open")
        XCTAssertTrue(m.sections.isEmpty, "空 query 不显示建议（复刻设计稿 filterCommands）")

        // ③ setQuery：有命中
        m.setQuery("web")
        assertConsistent(m, "setQuery(web)")
        XCTAssertEqual(m.results.map(\.id), ["h1", "h2", "f1"])
        XCTAssertEqual(m.selectedItemID, "h1")

        // ④ setQuery：精确匹配前移
        m.setQuery("web-02")
        assertConsistent(m, "setQuery(精确)")
        XCTAssertEqual(m.results.first?.id, "h2")

        // ⑤ setQuery：退回空串
        m.setQuery("")
        assertConsistent(m, "setQuery(空)")
        XCTAssertTrue(m.results.isEmpty)

        // ⑥ close
        m.setQuery("web")
        m.close()
        assertConsistent(m, "close")
        XCTAssertTrue(m.results.isEmpty)
        XCTAssertEqual(m.query, "")
    }

    /// 异步搜索回填 `dynamicItems` 之后也必须重算 —— 这是最容易漏的一条：
    /// 结果是从**另一个 Task**里填进来的，不经过 `setQuery` 的同步段。
    func testAsyncSearchResultsAreFoldedIntoSections() async {
        let m = CommandPaletteModel()
        m.searchDebounceNanos = 0
        m.searchProvider = { [self] q in
            [item("remote.\(q)", .file, "/var/log/\(q).log", "远程命中")]
        }
        m.open(items: sample)
        m.setQuery("web")
        // 防抖 0，但回填仍在另一个 Task 里 —— 等它跑完。
        await m.waitForSearch()

        assertConsistent(m, "异步搜索回填")
        XCTAssertTrue(m.results.contains { $0.id == "remote.web" },
                      "远程命中必须并进候选：\(m.results.map(\.id))")
    }

    /// 同 id 的动态项被静态项压过（去重保留首次出现）—— 换成存储之后
    /// 顺序仍要来自「静态在前」。
    func testDynamicItemsStillLoseToStaticOnesWithTheSameID() async {
        let m = CommandPaletteModel()
        m.searchDebounceNanos = 0
        m.searchProvider = { [self] _ in [item("h1", .file, "冒充 h1 的动态项")] }
        m.open(items: sample)
        m.setQuery("web")
        await m.waitForSearch()

        assertConsistent(m, "同 id 去重")
        XCTAssertEqual(m.results.filter { $0.id == "h1" }.count, 1)
        XCTAssertEqual(m.results.first { $0.id == "h1" }?.title, "web-01",
                       "静态项必须压过同 id 的动态项")
    }

    /// 选中项 id 仍然只做一次下标（不重跑 filter / dedupe / group），
    /// 且越界时为 nil。
    func testSelectedItemIDFollowsTheStoredResults() {
        let m = CommandPaletteModel()
        m.open(items: sample)
        m.setQuery("web")
        XCTAssertEqual(m.selectedItemID, "h1")
        m.moveSelection(by: 2)
        XCTAssertEqual(m.selectedItemID, "f1")
        m.moveSelection(by: 99)   // 钳在末尾
        XCTAssertEqual(m.selectedItemID, "f1")
        m.setQuery("完全没有这个词")
        XCTAssertNil(m.selectedItemID)
        XCTAssertTrue(m.results.isEmpty)
    }

    /// 形态闸门：`sections` / `results` 必须是存储属性、`query` 必须是
    /// `private(set)`（否则外部直接赋值就会绕过 `rebuild()`），
    /// 而且 filter → dedupe → group 这条链在整个模型里**只出现一次**。
    func testModelKeepsTheSingleEvaluationShape() throws {
        let source = try String(contentsOf: Self.repoRoot.appendingPathComponent(
            "uTerm/Features/CommandPalette/CommandPaletteModel.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("private(set) var query: String"),
                      "query 必须只能经 setQuery 改")
        XCTAssertTrue(source.contains("private(set) var sections: [CommandPaletteSection] = []"))
        XCTAssertTrue(source.contains("private(set) var results: [CommandPaletteItem] = []"))
        XCTAssertEqual(source.components(separatedBy: "groupCommandPaletteByMatchPriority").count - 1, 1,
                       "分组只能在 rebuild() 里跑一次")
        XCTAssertEqual(source.components(separatedBy: "filterCommandPalette").count - 1, 1,
                       "过滤只能在 rebuild() 里跑一次")
        XCTAssertFalse(source.contains("sections.flatMap(\\.items)\n    }"),
                       "results 不能改回「读一遍 sections」的计算属性")
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
