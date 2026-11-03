import AgentKit
import Foundation

/// uTerm 的模型目录：AgentKit 的 `AgentModelCatalog`（全部 provider 的可用模型列表）接上
/// uTerm 自己的 provider、端点校验与钥匙串。所有窗口的 Agent 输入区共用这一份。
@MainActor
enum AgentModelDirectory {
    static let catalog = AgentModelCatalog(describe: describe)

    /// 打开模型下拉时调：刷新过期 / 出错 / 换了端点的 provider；`force` 全部重拉。
    static func refresh(_ providers: [AIProvider], force: Bool = false,
                        keychain: AgentKeychain = AgentKeychain()) {
        catalog.retainOnly(Set(providers.map(\.id)))
        catalog.refresh(providers.map { source(for: $0, keychain: keychain) }, force: force)
    }

    /// 还没选模型、而列表已经拉到的 provider：替它选上默认模型（`AgentModelMenu.defaultModel`）。
    /// 新建的服务、从另一台设备同步过来还没选过模型的服务，都不必再去模型菜单里手选一次。
    /// 返回选了几个。
    @discardableResult
    static func fillMissingModels(_ providers: [AIProvider], in catalog: AgentModelCatalog = catalog) -> Int {
        var filled = 0
        for provider in providers where provider.model.isEmpty {
            guard let pick = AgentModelMenu.defaultModel(from: catalog.entry(for: provider.id)?.models ?? [])
            else { continue }
            provider.model = pick
            filled += 1
        }
        return filled
    }

    /// 只强制重拉这一个 provider（设置页换了 key / 测通了连接）。
    static func refreshOne(_ provider: AIProvider) {
        catalog.refresh([source(for: provider)], force: true)
    }

    static func source(for provider: AIProvider,
                       keychain: AgentKeychain = AgentKeychain()) -> AgentModelCatalog.Source {
        let kind = provider.kind
        let baseURL = provider.baseURL
        // 钥匙串在主线程上读一次，闭包里只带字符串。
        let key = keychain.load(for: provider.id) ?? ""
        return AgentModelCatalog.Source(providerID: provider.id,
                                        endpoint: "\(kind.rawValue)|\(baseURL)") {
            let url = try ProviderEndpointPolicy.resolve(configuredBaseURL: baseURL, kind: kind).get()
            return try await ProviderModelCatalog.fetchModels(kind: kind, baseURL: url, apiKey: key)
        }
    }

    nonisolated static func describe(_ error: Error) -> String {
        if let invalid = error as? ProviderEndpointPolicy.ValidationError {
            return "Base URL 无效：\(invalid.message)"
        }
        return ProviderModelCatalog.message(for: error)
    }
}
