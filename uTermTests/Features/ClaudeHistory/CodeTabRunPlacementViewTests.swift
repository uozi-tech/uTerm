import AppKit
import SwiftUI
import UDesignKit
import XCTest
@testable import uTerm

/// Code 标签页侧栏里跑着的会话画在哪（用户报的：跑着的会话被抽到列表最顶上一块没有标题的地方，不在它的组里；
/// 置顶一个跑着的（比如空闲的）会话看不出任何变化）。规则（`AgentHistoryRunPlacement`）：不另起一块，
/// 列表里有它那份记录的就在那份记录平常的位置——置顶了在「置顶」，否则在它那一组——只靠行上的状态区分；
/// 列表里没有记录的（还没对上记录的新会话）没有组可放，才在最顶上。
///
/// 真窗口里挂会话列表，按无障碍树里各元素的先后（同画出来的上下）核对。
@MainActor
final class CodeTabRunPlacementViewTests: XCTestCase {
    private typealias Session = AgentHistoryFakeSource.Session
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() async throws {
        try await super.setUp()
        suite = "run-placement-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        AccessibilityTreeForTests.enable(for: self)
    }

    override func tearDown() async throws {
        defaults?.removePersistentDomain(forName: suite)
        try await super.tearDown()
    }

    /// shop、infra、blog 三个项目各两个会话，shop 最新。
    private func history() async -> AgentHistoryModel {
        let now = Date()
        var sessions: [Session] = []
        for (index, project) in ["shop", "infra", "blog"].enumerated() {
            for n in 0..<2 {
                sessions.append(Session(id: "\(project)-\(n)", projectID: ClaudeProjectPath.encode("/srv/\(project)"),
                                        resumeDirectory: "/srv/\(project)", title: "\(project) 的第 \(n) 个会话",
                                        modifiedAt: now.addingTimeInterval(-TimeInterval(index * 1000 + n * 60))))
            }
        }
        let source = AgentHistoryFakeSource(tool: .claude, sessions: sessions)
        let history = AgentHistoryModel(source: source, preferredDirectory: nil, followsCurrentProject: false)
        history.pins = AgentHistoryPins(host: .local, defaults: defaults)
        await history.start()
        for _ in 0..<200 where history.hasMore || history.isListing { try? await Task.sleep(for: .milliseconds(5)) }
        return history
    }

    private func runRow(_ history: AgentHistoryModel, _ id: String?, title: String,
                        selected: Bool = false, directory: String = "/srv/infra") -> AgentHistoryRunRow {
        AgentHistoryRunRow(id: UUID(), title: title, tool: .claude, directory: directory, isSelected: selected,
                           path: id.flatMap { id in history.files.first { $0.sessionID == id }?.path },
                           status: AgentHistoryRunStatus {
                               .program(ProgramStatusRecord(state: .idle, app: "claude-code"))
                           })
    }

    /// 画出列表，返回无障碍树里的字（自上而下）。
    private func drawnLabels(_ history: AgentHistoryModel, runs: [AgentHistoryRunRow]) async throws -> [String] {
        let window = ProbeWindow.make(contentRect: NSRect(x: 0, y: 0, width: 320, height: 700),
                                      key: true, placement: .transparentOnScreen)
        let host = NSHostingView(rootView: AgentHistorySessionList(
            history: history, running: AgentHistoryRunning(rows: { runs }, onSelect: { _ in }))
            .frame(width: 320, height: 700)
            .background(UD.card))
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 700)
        window.contentView = host
        defer {
            window.contentView = NSView()
            window.orderOut(nil)
        }
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(40))
        }
        return Self.axStrings(host)
    }

    private func index(_ labels: [String], _ fragment: String, file: StaticString = #filePath,
                       line: UInt = #line) throws -> Int {
        try XCTUnwrap(labels.firstIndex { $0.contains(fragment) }, "画出了「\(fragment)」：\(labels)",
                      file: file, line: line)
    }

    /// 跑着的会话在它那一组里、排在组的最前面，它那一组排在别的组前面（运行中的会话始终高优先级）；只出现一次，
    /// 不另起一块放在最顶上。
    func testRunningSessionStaysInItsGroup() async throws {
        let history = await history()
        let labels = try await drawnLabels(history, runs: [runRow(history, "infra-1", title: "infra 的第 1 个会话")])
        let shopHeader = try index(labels, "shop，")
        let infraHeader = try index(labels, "infra，")
        let blogHeader = try index(labels, "blog，")
        let row = try index(labels, "infra 的第 1 个会话")
        let other = try index(labels, "infra 的第 0 个会话")
        XCTAssertGreaterThan(row, infraHeader, "在 infra 那一组里")
        XCTAssertLessThan(row, other, "排在组的最前面")
        XCTAssertLessThan(infraHeader, shopHeader, "有跑着的会话的组排在前面")
        XCTAssertLessThan(shopHeader, blogHeader, "其余的组照原来的先后")
        XCTAssertEqual(labels.filter { $0.contains("infra 的第 1 个会话") }.count, 1, "只出现一次")
        XCTAssertFalse(labels[row].contains(ProgramStatusRecord(state: .idle, app: "claude-code").statusLabel),
                       "空闲不标（同 Claude Code Desktop，只在等人处理时提醒）：\(labels[row])")
        XCTAssertTrue(labels.contains { $0.hasPrefix("infra，2 ") || $0.contains("infra，2") }, "infra 组仍是两个会话")
    }

    /// 置顶一个跑着的会话：它出现在「置顶」里（只在那里）；取消置顶回到它那一组。
    func testPinningARunningSessionMovesItIntoPinned() async throws {
        let history = await history()
        let infra1 = try XCTUnwrap(history.files.first { $0.sessionID == "infra-1" })
        history.pins?.toggle(infra1)
        let runs = [runRow(history, "infra-1", title: "infra 的第 1 个会话")]
        let pinned = try await drawnLabels(history, runs: runs)
        let pinnedHeader = try index(pinned, AgentHistoryText.pinnedTitle + "，")
        let shopHeader = try index(pinned, "shop，")
        let row = try index(pinned, "infra 的第 1 个会话")
        XCTAssertGreaterThan(row, pinnedHeader, "在「置顶」里")
        XCTAssertLessThan(row, shopHeader, "在「置顶」里")
        XCTAssertEqual(pinned.filter { $0.contains("infra 的第 1 个会话") }.count, 1, "只在「置顶」里出现一次")

        history.pins?.toggle(infra1)
        let unpinned = try await drawnLabels(history, runs: runs)
        XCTAssertNil(unpinned.firstIndex { $0.hasPrefix(AgentHistoryText.pinnedTitle + "，") }, "没有置顶了")
        let back = try index(unpinned, "infra 的第 1 个会话")
        XCTAssertGreaterThan(back, try index(unpinned, "infra，"), "回到 infra 那一组")
        XCTAssertLessThan(back, try index(unpinned, "blog，"), "回到 infra 那一组")
    }

    /// 列表里还没有记录的新会话：在它目录那一组的最上面（组标题之后、组里原来的行之前），不单独摆在列表最顶上
    ///（2026-11-26 实测：在 uTerm 目录里开的新会话摆在「置顶」上面，看着不属于任何项目）。
    func testNewRunSitsAtTheTopOfItsProjectGroup() async throws {
        let history = await history()
        let labels = try await drawnLabels(history, runs: [
            runRow(history, nil, title: AgentHistoryText.newSession),
            runRow(history, "infra-1", title: "infra 的第 1 个会话"),
        ])
        let fresh = try index(labels, AgentHistoryText.newSession)
        XCTAssertGreaterThan(fresh, try index(labels, "infra，"), "在 infra 那一组里")
        XCTAssertLessThan(fresh, try index(labels, "infra 的第 1 个会话"), "在组里原来的行之前")
        XCTAssertLessThan(fresh, try index(labels, "blog，"), "在 infra 那一组里")
        XCTAssertEqual(labels.filter { $0.contains(AgentHistoryText.newSession) }.count, 1, "只出现一次")
    }

    /// 对不上任何一组的（在列表里还没有的目录里开的）：在最顶上（第一个组标题之前）。
    func testNewRunInAnUnknownDirectoryStaysOnTop() async throws {
        let history = await history()
        let labels = try await drawnLabels(history, runs: [
            runRow(history, nil, title: AgentHistoryText.newSession, directory: "/srv/brand-new"),
            runRow(history, "infra-1", title: "infra 的第 1 个会话"),
        ])
        let fresh = try index(labels, AgentHistoryText.newSession)
        XCTAssertLessThan(fresh, try index(labels, "shop，"), "新会话在最顶上")
        XCTAssertGreaterThan(try index(labels, "infra 的第 1 个会话"), try index(labels, "infra，"),
                             "有记录的仍在它那一组")
    }

    /// 选中的跑着的会话在一个收着的组里（侧栏收起时从窄轨点开、重启后还原、新会话刚对上记录）：那一组自己打开，
    /// 不会找不到它。没选中的跑着的会话不动用户收起的组。
    func testSelectedRunInACollapsedGroupIsRevealed() async throws {
        let history = await history()
        let infra = "project:/srv/infra", blog = "project:/srv/blog"
        history.collapsedGroups.insert(infra)
        history.collapsedGroups.insert(blog)
        let labels = try await drawnLabels(history, runs: [
            runRow(history, "infra-1", title: "infra 的第 1 个会话", selected: true),
            runRow(history, "blog-0", title: "blog 的第 0 个会话"),
        ])
        XCTAssertFalse(history.collapsedGroups.contains(infra), "选中的跑着的会话那一组打开了")
        XCTAssertTrue(history.collapsedGroups.contains(blog), "没选中的不动用户收起的组")
        XCTAssertTrue(labels.contains { $0.contains("infra 的第 1 个会话") }, "看得到它那一行：\(labels)")
        XCTAssertFalse(labels.contains { $0.contains("blog 的第 0 个会话") }, "收着的组里的行照旧不画")
    }

    /// 选中的新会话（还没有记录）放进了一个收着的组：那一组自己打开，看得到它。
    func testSelectedNewRunInACollapsedGroupIsRevealed() async throws {
        let history = await history()
        let infra = "project:/srv/infra"
        history.collapsedGroups.insert(infra)
        let labels = try await drawnLabels(history, runs: [
            runRow(history, nil, title: AgentHistoryText.newSession, selected: true),
        ])
        XCTAssertFalse(history.collapsedGroups.contains(infra), "它那一组打开了")
        XCTAssertTrue(labels.contains { $0.contains(AgentHistoryText.newSession) }, "看得到它那一行：\(labels)")
    }

    /// 子树里所有无障碍元素的 label / value（同 `CodeTabRunTimeTests`）。
    private static func axStrings(_ root: Any, depth: Int = 0) -> [String] {
        guard depth < 60 else { return [] }
        var out: [String] = []
        let object = root as AnyObject
        if let label = object.accessibilityLabel?(), !label.isEmpty { out.append(label) }
        let valueSelector = NSSelectorFromString("accessibilityValue")
        if object.responds?(to: valueSelector) == true,
           let value = object.perform(valueSelector)?.takeUnretainedValue() as? String, !value.isEmpty {
            out.append(value)
        }
        if let children = object.accessibilityChildren?() {
            for child in children { out += axStrings(child, depth: depth + 1) }
        }
        return out
    }
}
