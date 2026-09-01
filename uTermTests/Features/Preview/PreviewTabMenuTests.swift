import XCTest
import AppKit
@testable import uTerm

// 改造前这里还有一条 `test_tabBarBackground_matches_editor_background_in_dark_mode`：
// 预览区自绘的标签条把底色调成 `EditorTheme.background`，好和下方编辑器无缝衔接。
// 标签条现在由共享组件 `UPaneGroupArea` 画，底色统一成 `UD.panel`（与 uTable 的
// 编辑组一致），那条断言的对象已经不存在。
@MainActor
final class PreviewTabMenuTests: XCTestCase {
    func test_contextMenuCloseTargets_followTabOrderAndScope() {
        let first = UUID()
        let target = UUID()
        let third = UUID()
        let fourth = UUID()
        let ordered = [first, target, third, fourth]

        XCTAssertEqual(
            PreviewTabMenuPlanner.closeTargets(
                for: .selected, targetID: target, orderedIDs: ordered),
            [target])
        XCTAssertEqual(
            PreviewTabMenuPlanner.closeTargets(
                for: .others, targetID: target, orderedIDs: ordered),
            [first, third, fourth])
        XCTAssertEqual(
            PreviewTabMenuPlanner.closeTargets(
                for: .tabsToRight, targetID: target, orderedIDs: ordered),
            [third, fourth])
        XCTAssertEqual(
            PreviewTabMenuPlanner.closeTargets(
                for: .all, targetID: target, orderedIDs: ordered),
            ordered)
    }

    func test_contextMenuCloseTargets_areEmptyForMissingTarget() {
        XCTAssertTrue(
            PreviewTabMenuPlanner.closeTargets(
                for: .all,
                targetID: UUID(),
                orderedIDs: [UUID(), UUID()])
                .isEmpty)
    }
}
