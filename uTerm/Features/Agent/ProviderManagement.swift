import Foundation
import SwiftData

/// 模型服务（`AIProvider`）的增删、排序、校验、存 Key 与测试连接。
/// macOS 设置页（`ProvidersSettingsView` / `ProviderEditView`）与 iOS 设置页
/// （`ProvidersScreen` / `ProviderEditScreen`）共用：两端只是表单长得不一样。
///
/// 模型不在这里选：Agent 输入区的模型菜单把所有 provider 的 `/v1/models` 列表合在一起，
/// 在那里直接切换（`AgentModelDirectory`）。这里的「测试连接」就是拉一次模型列表。
@MainActor
enum ProviderManagement {
    /// 「测试连接」的结果。
    struct ConnectionResult: Equatable {
        let ok: Bool
        let message: String
    }

    // MARK: - 增删排序

    /// 新建一条 provider 排在最后；`model` 留空，由输入区的模型菜单来选。
    @discardableResult
    static func add(name: String = String(localized: "新模型服务"),
                    kind: ProviderKind = .anthropic,
                    baseURL: String? = nil,
                    in context: ModelContext) -> AIProvider {
        let existing = (try? context.fetch(FetchDescriptor<AIProvider>())) ?? []
        let provider = AIProvider(name: name,
                                  kind: kind,
                                  baseURL: baseURL ?? ProviderPreset.defaultBaseURL(for: kind),
                                  model: "",
                                  sortOrder: (existing.map(\.sortOrder).max() ?? -1) + 1)
        context.insert(provider)
        try? context.save()
        return provider
    }

    /// 删除 provider 连同钥匙串里的 Key。
    static func delete(_ provider: AIProvider, in context: ModelContext,
                       keychain: AgentKeychain = AgentKeychain()) {
        try? keychain.delete(for: provider.id)
        context.delete(provider)
        try? context.save()
    }

    /// 按列表拖动重排后的顺序重写 `sortOrder`（`providers` 须是当前显示顺序）。
    static func move(_ providers: [AIProvider], fromOffsets source: IndexSet, toOffset destination: Int,
                     in context: ModelContext) {
        // 与 SwiftUI 的 `move(fromOffsets:toOffset:)` 同语义（`destination` 是移动前的下标）；
        // 不为这一行把 SwiftUI 拉进管理层。
        let moving = source.map { providers[$0] }
        var ordered = providers.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        ordered.insert(contentsOf: moving, at: destination - source.count(in: 0..<destination))
        for (index, provider) in ordered.enumerated() where provider.sortOrder != index {
            provider.sortOrder = index
        }
        try? context.save()
    }

    // MARK: - 列表文案

    /// 服务列表行名称下面那行：类型 · 地址（如「Anthropic · api.anthropic.com」）。
    /// 不显示模型——模型在 Agent 输入区的模型菜单里切换，这里没有设它的地方。
    nonisolated static func summary(kind: ProviderKind, baseURL: String) -> String {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let configured = trimmed.isEmpty ? ProviderPreset.defaultBaseURL(for: kind) : trimmed
        let address = URLComponents(string: configured).flatMap { components in
            components.host.map { host in components.port.map { "\(host):\($0)" } ?? host }
        } ?? configured
        return "\(kind.displayName) · \(address)"
    }

    static func summary(_ provider: AIProvider) -> String {
        summary(kind: provider.kind, baseURL: provider.baseURL)
    }

    // MARK: - 校验

    /// 名称必填。
    nonisolated static func nameError(_ name: String) -> String? {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? String(localized: "名称不能为空") : nil
    }

    /// Base URL 必填；远程端点须 HTTPS，loopback 开发服务可用 HTTP。
    nonisolated static func baseURLError(_ baseURL: String, kind: ProviderKind) -> String? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return String(localized: "Base URL 不能为空") }
        return ProviderEndpointPolicy.validationMessage(configuredBaseURL: trimmed, kind: kind)
    }

    /// 换类型时若 Base URL 还是旧类型的预置，跟着换成新类型的预置；用户自定义过的不动。
    nonisolated static func baseURL(_ current: String, switchingFrom old: ProviderKind,
                                    to new: ProviderKind) -> String {
        current == ProviderPreset.defaultBaseURL(for: old) ? ProviderPreset.defaultBaseURL(for: new) : current
    }

    /// 把类型改到 `kind`，按 `baseURL(_:switchingFrom:to:)` 同步 Base URL。
    static func setKind(_ kind: ProviderKind, on provider: AIProvider) {
        provider.baseURL = baseURL(provider.baseURL, switchingFrom: provider.kind, to: kind)
        provider.kindRaw = kind.rawValue
    }

    // MARK: - Key 与连接

    static func hasKey(_ provider: AIProvider, keychain: AgentKeychain = AgentKeychain()) -> Bool {
        keychain.load(for: provider.id) != nil
    }

    /// 把 Key 存进钥匙串；换了 key，旧模型列表（可能是认证失败）作废，立刻用新 key 重拉。
    static func saveKey(_ draft: String, for provider: AIProvider,
                        keychain: AgentKeychain = AgentKeychain()) throws {
        let key = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        try keychain.save(key, for: provider.id)
        AgentModelDirectory.refreshOne(provider)
    }

    /// 测试连接 = 拉一次 `/v1/models`：认证、Base URL、网络一次验完，顺带告诉用户有几个
    /// 模型可选。`keyDraft` 非空时用它（先试再保存），否则用钥匙串里的；用钥匙串里的 key
    /// 测通时同步刷新输入区的模型目录。
    static func testConnection(_ provider: AIProvider, keyDraft: String = "",
                               keychain: AgentKeychain = AgentKeychain()) async -> ConnectionResult {
        let draft = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let usesSavedKey = draft.isEmpty
        let key = usesSavedKey ? (keychain.load(for: provider.id) ?? "") : draft
        guard !key.isEmpty else {
            return ConnectionResult(ok: false, message: String(localized: "先填写或保存 API Key"))
        }
        guard case .success(let baseURL) = ProviderEndpointPolicy.resolve(
            configuredBaseURL: provider.baseURL, kind: provider.kind) else {
            return ConnectionResult(ok: false,
                                    message: baseURLError(provider.baseURL, kind: provider.kind)
                                        ?? String(localized: "Base URL 无效或不安全"))
        }
        do {
            let ids = try await ProviderModelCatalog.fetchModels(
                kind: provider.kind, baseURL: baseURL, apiKey: key)
            if usesSavedKey { AgentModelDirectory.refreshOne(provider) }
            return ConnectionResult(ok: true, message: ids.isEmpty ? String(localized: "连接成功，但该端点没有列出任何模型")
                                                                   : String(localized: "连接成功 · \(ids.count) 个可用模型"))
        } catch {
            return ConnectionResult(ok: false, message: AgentModelDirectory.describe(error))
        }
    }
}
