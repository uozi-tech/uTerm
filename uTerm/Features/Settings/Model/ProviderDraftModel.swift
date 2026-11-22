import Foundation
import Observation

/// 模型服务编辑页上「API Key 草稿 + 保存 + 测试连接」的状态（mac `ProviderEditView`、
/// iOS `ProviderEditScreen` / `NewProviderSheet` 共用）。名称 / 类型 / Base URL 直接绑在
/// `AIProvider` 上，不经这里。
///
/// 钥匙串读写与网络请求经 `Operations` 注入，测试换成内存实现，不碰真钥匙串。
@MainActor @Observable
final class ProviderDraftModel {
    /// 钥匙串与网络的三处副作用。
    struct Operations {
        var hasKey: @MainActor (AIProvider) -> Bool
        var saveKey: @MainActor (_ key: String, _ provider: AIProvider) throws -> Void
        var testConnection: @MainActor (_ provider: AIProvider, _ keyDraft: String) async
            -> ProviderManagement.ConnectionResult

        static func live(keychain: AgentKeychain = AgentKeychain()) -> Operations {
            Operations(
                hasKey: { ProviderManagement.hasKey($0, keychain: keychain) },
                saveKey: { try ProviderManagement.saveKey($0, for: $1, keychain: keychain) },
                testConnection: { await ProviderManagement.testConnection($0, keyDraft: $1, keychain: keychain) })
        }
    }

    /// 正在编辑的服务。新建表单用一个不进库的临时对象，测试前换成最新草稿。
    var provider: AIProvider
    var keyDraft = ""
    private(set) var keySaved = false
    private(set) var keySaveError: String?
    private(set) var testInFlight = false
    private(set) var testResult: ProviderManagement.ConnectionResult?
    /// 钥匙串里已有这条服务的 Key。`refreshHasKey()` 与成功保存后更新。
    private(set) var hasKey = false

    @ObservationIgnored private let operations: Operations

    init(provider: AIProvider, operations: Operations = .live()) {
        self.provider = provider
        self.operations = operations
        self.hasKey = operations.hasKey(provider)
    }

    /// 去掉首尾空白后的 Key 草稿；空串表示没填。
    var trimmedKeyDraft: String {
        keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canSaveKey: Bool { !trimmedKeyDraft.isEmpty }

    func refreshHasKey() {
        hasKey = operations.hasKey(provider)
    }

    /// 把草稿存进钥匙串；成功后清空草稿。`errorDescription` 决定失败文案里错误的写法
    /// （mac 历来打印错误本身，iOS 用 `localizedDescription`）。
    func saveKey(errorDescription: (Error) -> String = { "\($0)" }) {
        guard canSaveKey else { return }
        do {
            try operations.saveKey(trimmedKeyDraft, provider)
            keyDraft = ""
            keySaveError = nil
            keySaved = true
            hasKey = true
        } catch {
            keySaveError = String(localized: "保存到钥匙串失败：\(errorDescription(error))")
            keySaved = false
        }
    }

    /// 测试连接 = 拉一次 `/v1/models`。草稿非空时用草稿（先试再保存），否则用钥匙串里的。
    func testConnection() async {
        testInFlight = true
        defer { testInFlight = false }
        testResult = await operations.testConnection(provider, keyDraft)
    }

    /// 换了编辑对象：清掉上一条的草稿与结果。
    func reset(to provider: AIProvider) {
        self.provider = provider
        keyDraft = ""
        keySaved = false
        keySaveError = nil
        testInFlight = false
        testResult = nil
        hasKey = operations.hasKey(provider)
    }
}
