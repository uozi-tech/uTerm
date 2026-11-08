import XCTest
@testable import uTerm

/// 模型服务编辑页的草稿状态（`ProviderDraftModel`）。钥匙串与网络换成内存实现，
/// 不碰真钥匙串（锁屏时真钥匙串会 -25308）。
@MainActor
final class ProviderDraftModelTests: XCTestCase {
    @MainActor private final class FakeBackend {
        var keys: [UUID: String] = [:]
        var saveError: Error?
        var testCalls: [(name: String, keyDraft: String)] = []
        var testResult = ProviderManagement.ConnectionResult(ok: true, message: "连接成功 · 3 个可用模型")

        var operations: ProviderDraftModel.Operations {
            ProviderDraftModel.Operations(
                hasKey: { self.keys[$0.id] != nil },
                saveKey: { key, provider in
                    if let error = self.saveError { throw error }
                    self.keys[provider.id] = key
                },
                testConnection: { provider, draft in
                    self.testCalls.append((provider.name, draft))
                    return self.testResult
                })
        }
    }

    private struct Boom: Error, CustomStringConvertible {
        var description: String { "boom" }
    }

    private func provider(_ name: String = "Claude") -> AIProvider {
        AIProvider(name: name, kind: .anthropic, baseURL: ProviderPreset.anthropicBaseURL, model: "")
    }

    func testDraftIsTrimmedAndGatesSave() {
        let backend = FakeBackend()
        let model = ProviderDraftModel(provider: provider(), operations: backend.operations)
        XCTAssertFalse(model.canSaveKey)
        model.keyDraft = "   \n"
        XCTAssertFalse(model.canSaveKey)
        model.saveKey()
        XCTAssertTrue(backend.keys.isEmpty, "空草稿不写钥匙串")
        model.keyDraft = "  sk-123 \n"
        XCTAssertEqual(model.trimmedKeyDraft, "sk-123")
        XCTAssertTrue(model.canSaveKey)
    }

    func testSaveSuccessClearsDraftAndMarksHasKey() {
        let backend = FakeBackend()
        let p = provider()
        let model = ProviderDraftModel(provider: p, operations: backend.operations)
        XCTAssertFalse(model.hasKey)
        model.keyDraft = " sk-abc "
        model.saveKey()
        XCTAssertEqual(backend.keys[p.id], "sk-abc")
        XCTAssertEqual(model.keyDraft, "")
        XCTAssertTrue(model.keySaved)
        XCTAssertNil(model.keySaveError)
        XCTAssertTrue(model.hasKey)
    }

    func testSaveFailureKeepsDraftAndReportsError() {
        let backend = FakeBackend()
        backend.saveError = Boom()
        let model = ProviderDraftModel(provider: provider(), operations: backend.operations)
        model.keyDraft = "sk-abc"
        model.saveKey()
        XCTAssertEqual(model.keyDraft, "sk-abc")
        XCTAssertFalse(model.keySaved)
        XCTAssertEqual(model.keySaveError, "保存到钥匙串失败：boom")
        model.saveKey(errorDescription: { _ in "本地化" })
        XCTAssertEqual(model.keySaveError, "保存到钥匙串失败：本地化")
    }

    func testTestConnectionPassesDraftAndStoresResult() async {
        let backend = FakeBackend()
        let model = ProviderDraftModel(provider: provider("DeepSeek"), operations: backend.operations)
        model.keyDraft = "sk-draft"
        await model.testConnection()
        XCTAssertEqual(backend.testCalls.map(\.name), ["DeepSeek"])
        XCTAssertEqual(backend.testCalls.map(\.keyDraft), ["sk-draft"])
        XCTAssertEqual(model.testResult, backend.testResult)
        XCTAssertFalse(model.testInFlight)
    }

    func testSwappingProviderBeforeTestUsesTheNewOne() async {
        let backend = FakeBackend()
        let model = ProviderDraftModel(provider: provider("占位"), operations: backend.operations)
        model.provider = provider("草稿")
        await model.testConnection()
        XCTAssertEqual(backend.testCalls.map(\.name), ["草稿"])
    }

    func testResetClearsState() async {
        let backend = FakeBackend()
        let other = provider("Other")
        backend.keys[other.id] = "sk-other"
        let model = ProviderDraftModel(provider: provider(), operations: backend.operations)
        model.keyDraft = "sk-1"
        model.saveKey()
        await model.testConnection()
        model.reset(to: other)
        XCTAssertTrue(model.provider === other)
        XCTAssertEqual(model.keyDraft, "")
        XCTAssertFalse(model.keySaved)
        XCTAssertNil(model.keySaveError)
        XCTAssertNil(model.testResult)
        XCTAssertTrue(model.hasKey, "换到的服务钥匙串里已有 Key")
    }
}
