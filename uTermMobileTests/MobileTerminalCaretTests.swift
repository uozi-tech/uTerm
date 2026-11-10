import XCTest
@testable import uTermMobile

/// 收起键盘后用户还在看同一个终端：换引擎之前这里核的是「光标继续是实心块，不变成表示失焦的空心框」，
/// 靠的是旧引擎的本地补丁给的 `caretViewTracksFocus = false`。
///
/// 换成 GhosttyKit 之后这条行为没有了：光标由引擎画，视图不是第一响应者时引擎一律画空心框，宿主没有开关
///（迁移计划 `docs/ghostty-migration-plan.md` §7「会丢的」第一条，user 已知情）。要找回来得改引擎或提给上游
///（计划 §6 的可选项「iOS 收键盘仍画实心光标」）。那之前这条用例没有可核的对应物，留着文件和说明，跳过。
@MainActor
final class MobileTerminalCaretTests: XCTestCase {
    func testCaretStaysSolidAfterTheKeyboardCollapses() throws {
        throw XCTSkip("GhosttyKit 失焦时画空心光标，宿主改不了（迁移计划 §7）；引擎支持之后再恢复这条用例")
    }
}
