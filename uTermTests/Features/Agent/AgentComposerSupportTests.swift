import AgentKit
import XCTest
@testable import uTerm

/// 两端 Agent 输入区共用的编排（`AgentComposerSupport`）：模型菜单、思考深度、
/// 草稿 / 排队 / 停止的状态与动作。macOS `AgentComposer` 与 iOS `MAgentComposer`
/// 只负责画，行为由这里守。
@MainActor
final class AgentComposerSupportTests: XCTestCase {
    private func provider(model: String = "m", kind: ProviderKind = .openai) -> AIProvider {
        AIProvider(name: "t", kind: kind, baseURL: "https://x", model: model)
    }

    private func preferences() throws -> AgentReasoningPreferences {
        let suite = "AgentComposerSupportTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return AgentReasoningPreferences(defaults: defaults)
    }

    // MARK: - 模型菜单

    func testGroupsFollowSortOrderAndReportStatus() async throws {
        let suite = "AgentComposerSupportTests-catalog-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = AgentModelCatalog(defaults: defaults, describe: { _ in "boom" })
        let a = AIProvider(name: "", kind: .anthropic, baseURL: "", model: "claude-legacy", sortOrder: 1)
        let b = AIProvider(name: "DeepSeek", kind: .openai, baseURL: "", model: "", sortOrder: 0)
        let c = AIProvider(name: "Pending", kind: .openai, baseURL: "", model: "", sortOrder: 2)
        catalog.refresh([
            .init(providerID: a.id, endpoint: "a") { ["claude-opus-4-7"] },
            .init(providerID: b.id, endpoint: "b") { throw URLError(.timedOut) },
        ])
        await catalog.waitUntilSettled()

        let groups = AgentModelMenu.groups(providers: [a, b, c], catalog: catalog)
        // 没起名的 provider 用类型名当组名。
        XCTAssertEqual(groups.map(\.title), ["DeepSeek", "Anthropic", "Pending"])
        XCTAssertEqual(groups[0].status, .failed("boom"))
        XCTAssertEqual(groups[1].status, .ready)
        XCTAssertEqual(groups[2].status, .loading, "从没拉过的 provider 算加载中")
        // 当前选中但列表里没有的那个排最前并标注。
        XCTAssertEqual(groups[1].items.map(\.model), ["claude-legacy", "claude-opus-4-7"])
        XCTAssertEqual(groups[1].items.map(\.detail), ["不在列表中", nil])
        XCTAssertEqual(groups[1].items.first?.id, AgentModelMenu.itemID(a))
        XCTAssertNil(AgentModelMenu.itemID(b), "没选模型的 provider 没有选中项")
    }

    func testLabelAndHelp() {
        XCTAssertEqual(AgentModelMenu.label(nil), "选择模型")
        XCTAssertEqual(AgentModelMenu.help(nil), "还没有配置模型服务")
        let empty = provider(model: "")
        XCTAssertEqual(AgentModelMenu.label(empty), "选择模型")
        XCTAssertEqual(AgentModelMenu.help(empty), "t：还没有选择模型")
        let chosen = provider(model: "gpt-5")
        XCTAssertEqual(AgentModelMenu.label(chosen), "gpt-5")
        XCTAssertEqual(AgentModelMenu.help(chosen), "t · gpt-5")
    }

    func testSelectModelWritesProviderAndActivatesIt() {
        let first = provider(model: "a")
        let second = AIProvider(name: "s", kind: .anthropic, baseURL: "https://y", model: "", sortOrder: 1)
        let model = AssistantModel(client: MockLLMClient(events: []), provider: first, apiKey: "k")
        model.providers = [first, second]

        let id = model.selectModel(AgentModelItem(providerID: second.id, model: "claude-opus-4-7", detail: nil))

        XCTAssertEqual(id, second.id)
        XCTAssertEqual(second.model, "claude-opus-4-7")
        XCTAssertEqual(model.activeProvider?.id, second.id)
        XCTAssertNil(model.selectModel(AgentModelItem(providerID: UUID(), model: "x", detail: nil)),
                     "已删除的 provider 选不中")
    }

    // MARK: - 思考深度

    func testEffortChoiceFollowsModelSupportAndWritesPreference() throws {
        let p = provider(model: "claude-opus-4-7", kind: .anthropic)
        let model = AssistantModel(client: MockLLMClient(events: []), provider: p, apiKey: "k")
        XCTAssertNil(model.effortChoice, "不带思考参数的状态机不出思考深度菜单")

        let prefs = try preferences()
        model.reasoningPreferences = prefs
        let choice = try XCTUnwrap(model.effortChoice)
        XCTAssertEqual(choice.options.first, AgentEffortOption(value: nil, label: "默认"))
        XCTAssertNil(choice.selection)
        XCTAssertEqual(choice.selectedLabel, "默认")

        choice.select(AgentReasoningEffort.high.rawValue)
        XCTAssertEqual(prefs.effort(providerID: p.id, model: p.model), .high)
        XCTAssertEqual(model.effortChoice?.selection, AgentReasoningEffort.high.rawValue)

        p.model = "gpt-4o-mini"
        p.kindRaw = ProviderKind.openai.rawValue
        XCTAssertNil(model.effortChoice, "不支持思考深度的模型不出菜单")
    }

    // MARK: - 草稿与动作

    func testTakeDraftClearsInputOnlyWhenThereIsText() {
        let model = AssistantModel(client: MockLLMClient(events: []), provider: provider(), apiKey: "k")
        model.input = "  \n "
        XCTAssertFalse(model.hasDraft)
        XCTAssertNil(model.takeDraft())
        XCTAssertEqual(model.input, "  \n ", "空白草稿不动")

        model.input = " df -h "
        XCTAssertTrue(model.hasDraft)
        XCTAssertEqual(model.takeDraft(), " df -h ", "原样交给 submit，修剪由状态机做")
        XCTAssertEqual(model.input, "")
    }

    func testAppendContextStartsOrExtendsDraft() {
        let model = AssistantModel(client: MockLLMClient(events: []), provider: provider(), apiKey: "k")
        model.appendContext("web-01")
        XCTAssertEqual(model.input, "上下文：\nweb-01")
        model.input = "看下磁盘"
        model.appendContext("web-01")
        XCTAssertEqual(model.input, "看下磁盘\n\n上下文：\nweb-01")
    }

    func testPendingCardStopStatusAndPlaceholder() async {
        let client = MockLLMClient(events: [
            .toolCall(LLMToolCall(id: "c1", name: "run_command", argumentsJSON: #"{"command":"ls"}"#)),
        ])
        let model = AssistantModel(client: client, provider: provider(), apiKey: "k")
        model.executor = MockCommandExecutor()
        XCTAssertNil(model.firstPendingToolCallID)
        XCTAssertEqual(model.composerPlaceholder("问点什么"), "问点什么")
        XCTAssertNil(model.composerStatus)

        model.input = "列目录"
        await model.send(serverContext: "")
        XCTAssertEqual(model.state, .awaitingApproval)
        XCTAssertEqual(model.firstPendingToolCallID, "c1")
        XCTAssertEqual(model.composerPlaceholder("问点什么"), "Agent 正在处理，输入会排队发送…")

        model.stop()
        XCTAssertNil(model.firstPendingToolCallID, "停止后待确认卡被跳过")
        XCTAssertEqual(model.composerStatus, "已停止")
    }

    // MARK: - 审批档位

    func testSafetyMenuOrderAndSymbols() {
        XCTAssertEqual(AgentSafety.byAutonomy, [.confirm, .readAuto, .auto])
        XCTAssertEqual(Set(AgentSafety.byAutonomy), Set(AgentSafety.allCases))
        XCTAssertEqual(Set(AgentSafety.allCases.map(\.symbolName)).count, AgentSafety.allCases.count)
    }

    func testPromptExamplesAreGroupedAndNonEmpty() {
        XCTAssertEqual(AgentPromptExamples.groups.map(\.tag), ["诊断", "配置", "部署"])
        XCTAssertTrue(AgentPromptExamples.groups.allSatisfy { !$0.items.isEmpty })
    }
}
