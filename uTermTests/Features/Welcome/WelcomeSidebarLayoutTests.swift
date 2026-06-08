import XCTest
@testable import uTerm

final class WelcomeSidebarLayoutTests: XCTestCase {
    func testGroupBuiltInRowsStartWithAllHosts() {
        let rows = WelcomeSidebarLayout.groupBuiltInRows(ungroupedCount: 0)

        XCTAssertEqual(rows.map(\.section), [.allHosts])
        XCTAssertEqual(rows.map(\.title), ["全部"])
    }

    func testUngroupedRowStaysAfterAllHosts() {
        let rows = WelcomeSidebarLayout.groupBuiltInRows(ungroupedCount: 2)

        XCTAssertEqual(rows.map(\.section), [.allHosts, .ungrouped])
        XCTAssertEqual(rows.map(\.title), ["全部", "未分组"])
    }

    func testProfileDropTargetsOnlyIncludeGroupsAndUngrouped() throws {
        let group = try XCTUnwrap(WelcomeSidebarProfileDropTarget(section: .group("prod")))
        XCTAssertEqual(group.groupName, "prod")

        let ungrouped = try XCTUnwrap(WelcomeSidebarProfileDropTarget(section: .ungrouped))
        XCTAssertNil(ungrouped.groupName)

        XCTAssertNil(WelcomeSidebarProfileDropTarget(section: .allHosts))
        XCTAssertNil(WelcomeSidebarProfileDropTarget(section: .pinned))
        XCTAssertNil(WelcomeSidebarProfileDropTarget(section: .recent))
    }

    func testGroupRowsUseCombinedDropDelegateForGroupsAndProfiles() throws {
        let source = try String(contentsOf: repoRoot.appendingPathComponent(
            "uTerm/Features/Welcome/Views/WelcomeSidebar.swift"
        ), encoding: .utf8)

        XCTAssertTrue(source.contains("WelcomeSidebarGroupDragModifier"))
        XCTAssertTrue(source.contains("WelcomeSidebarGroupDropDelegate"))
        XCTAssertFalse(source.contains(".modifier(GroupRowDragModifier("))
    }

    func testDroppingProfileOntoGroupDoesNotChangeCurrentSidebarFilter() throws {
        let source = try String(contentsOf: repoRoot.appendingPathComponent(
            "uTerm/Features/Welcome/Views/WelcomeView.swift"
        ), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private func moveProfileToGroup"))
        let end = try XCTUnwrap(source[start.upperBound...].range(of: "\n    private func deleteProfile"))
        let functionSource = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertFalse(functionSource.contains("filter.section"))
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
