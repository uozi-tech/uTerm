import XCTest
import SwiftData
@testable import uTerm

/// 两端设置页共用的模型服务管理（`ProviderManagement`）：增删、排序、校验、换类型。
@MainActor
final class ProviderManagementTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: AIProvider.self, configurations: config)
        addTeardownBlock { _ = container }
        return container.mainContext
    }

    private func ordered(_ context: ModelContext) throws -> [AIProvider] {
        try context.fetch(FetchDescriptor<AIProvider>(sortBy: [SortDescriptor(\.sortOrder)]))
    }

    func testAddAppendsWithPresetAndNoModel() throws {
        let context = try makeContext()
        let first = ProviderManagement.add(in: context)
        XCTAssertEqual(first.sortOrder, 0)
        XCTAssertEqual(first.kind, .anthropic)
        XCTAssertEqual(first.baseURL, ProviderPreset.anthropicBaseURL)
        XCTAssertEqual(first.model, "", "模型在输入区的模型菜单里选，新建时留空")

        let second = ProviderManagement.add(name: "DeepSeek", kind: .openai, in: context)
        XCTAssertEqual(second.sortOrder, 1)
        XCTAssertEqual(second.baseURL, ProviderPreset.openAIBaseURL)
        XCTAssertEqual(try ordered(context).map(\.name), ["新 Provider", "DeepSeek"])
    }

    func testDeleteRemovesProvider() throws {
        let context = try makeContext()
        let provider = ProviderManagement.add(in: context)
        ProviderManagement.delete(provider, in: context)
        XCTAssertTrue(try ordered(context).isEmpty)
    }

    func testMoveRewritesSortOrderLikeSwiftUIMove() throws {
        let context = try makeContext()
        for name in ["a", "b", "c", "d"] { ProviderManagement.add(name: name, in: context) }

        // 拖 a 到 c 之后（SwiftUI 的 destination 是移动前的下标）。
        ProviderManagement.move(try ordered(context), fromOffsets: [0], toOffset: 3, in: context)
        XCTAssertEqual(try ordered(context).map(\.name), ["b", "c", "a", "d"])
        XCTAssertEqual(try ordered(context).map(\.sortOrder), [0, 1, 2, 3])

        // 拖 d 到最前。
        ProviderManagement.move(try ordered(context), fromOffsets: [3], toOffset: 0, in: context)
        XCTAssertEqual(try ordered(context).map(\.name), ["d", "b", "c", "a"])

        // 一次拖多行。
        ProviderManagement.move(try ordered(context), fromOffsets: [0, 2], toOffset: 4, in: context)
        XCTAssertEqual(try ordered(context).map(\.name), ["b", "a", "d", "c"])
    }

    func testValidation() {
        XCTAssertEqual(ProviderManagement.nameError("  "), "名称不能为空")
        XCTAssertNil(ProviderManagement.nameError("Claude"))
        XCTAssertEqual(ProviderManagement.baseURLError(" ", kind: .openai), "Base URL 不能为空")
        XCTAssertNil(ProviderManagement.baseURLError("https://api.deepseek.com", kind: .openai))
        XCTAssertNil(ProviderManagement.baseURLError("http://localhost:11434", kind: .openai),
                     "loopback 开发服务可用 HTTP")
        XCTAssertNotNil(ProviderManagement.baseURLError("http://example.com", kind: .openai),
                        "远程端点须 HTTPS")
    }

    func testSummaryShowsKindAndAddressNotModel() {
        XCTAssertEqual(ProviderManagement.summary(kind: .anthropic, baseURL: ""), "Anthropic · api.anthropic.com",
                       "没填 Base URL 时显示该类型的预置地址")
        XCTAssertEqual(ProviderManagement.summary(kind: .openai, baseURL: " https://api.deepseek.com "),
                       "OpenAI / 兼容 · api.deepseek.com")
        XCTAssertEqual(ProviderManagement.summary(kind: .openai, baseURL: "http://localhost:11434"),
                       "OpenAI / 兼容 · localhost:11434")
        let provider = AIProvider(name: "p", kind: .anthropic, baseURL: ProviderPreset.anthropicBaseURL,
                                  model: "claude-opus-4-7")
        XCTAssertFalse(ProviderManagement.summary(provider).contains("claude"), "列表不显示模型")
    }

    func testSwitchingKindOnlyReplacesPresetBaseURL() {
        let provider = AIProvider(name: "p", kind: .anthropic, baseURL: ProviderPreset.anthropicBaseURL, model: "")
        ProviderManagement.setKind(.openai, on: provider)
        XCTAssertEqual(provider.kind, .openai)
        XCTAssertEqual(provider.baseURL, ProviderPreset.openAIBaseURL)

        provider.baseURL = "https://api.deepseek.com"
        ProviderManagement.setKind(.anthropic, on: provider)
        XCTAssertEqual(provider.kind, .anthropic)
        XCTAssertEqual(provider.baseURL, "https://api.deepseek.com", "自定义过的 Base URL 不动")
    }

    func testConnectionWithoutKeyFailsBeforeNetwork() async {
        let provider = AIProvider(name: "p", kind: .openai, baseURL: "https://x", model: "")
        let keychain = AgentKeychain(service: "ProviderManagementTests-\(UUID().uuidString)")
        let result = await ProviderManagement.testConnection(provider, keychain: keychain)
        XCTAssertEqual(result, .init(ok: false, message: "请先填或保存 API Key"))
    }
}
