import XCTest
import UDesignKit
@testable import uTerm

final class AssistantInputBarLayoutTests: XCTestCase {
    /// 窄面板里模型名要给审批档位与主操作钮让位：收缩档必须明显比完整档窄。
    func testModelLabelShrinksInCompactTier() {
        XCTAssertLessThan(AgentComposerLayout.modelLabelCompactWidth,
                          AgentComposerLayout.modelLabelMaxWidth / 2)
    }

    /// 菜单按「从保守到放权」排，且三档一个不少。
    func testSafetyMenuListsEveryModeByAutonomy() {
        XCTAssertEqual(AgentSafety.byAutonomy, [.confirm, .readAuto, .auto])
        XCTAssertEqual(Set(AgentSafety.byAutonomy), Set(AgentSafety.allCases))
        XCTAssertEqual(Set(AgentSafety.allCases.map(\.symbolName)).count, AgentSafety.allCases.count)
    }

    // 卡片、发送 ⇄ 停止、回车 / esc 的守卫住在 uAppKit 的 `UDAgentComposerTests`：
    // 组件本体在共享包里，守卫跟着源码走。
}
