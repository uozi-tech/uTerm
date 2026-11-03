import AgentKit
import SwiftData
import SwiftUI

/// 把 SwiftData providers + @AppStorage activeProviderID 灌进 assistant model。
/// 拆成独立 modifier 是为了让 `workspaceBody` 主表达式不至于让编译器超时；
/// `[AIProvider]` 是 `@Model` class，非 `Equatable`，所以 onChange 用 `id` 列表比较。
///
/// macOS 工作区 / 终端窗口与 iOS 终端 Agent 共用。持久化选择失效（provider 已删）时
/// 不必在这里兜底：`AssistantModel.activeProvider` 自己回退到排序第一个。
struct AssistantBindingModifier: ViewModifier {
    let assistant: AssistantModel
    let providers: [AIProvider]
    let activeProviderIDString: String

    func body(content: Content) -> some View {
        content
            .onAppear {
                assistant.providers = providers
                assistant.activeProviderID = UUID(uuidString: activeProviderIDString)
            }
            .onChange(of: providers.map(\.id)) { _, _ in
                assistant.providers = providers
            }
            .onChange(of: activeProviderIDString) { _, new in
                assistant.activeProviderID = UUID(uuidString: new)
            }
    }
}

/// Agent 面板出现时开启落库、灌入审批档位，并在档位变化时跟上（两端每个 Agent 面板
/// 同一写法：移动端曾漏掉这一步，`approvalMode` 恒为 `.confirm`，拨盘选什么都不生效）。
///
/// `attach(context:)` 幂等，会话由首次发送惰性创建——空 Agent 面板不会污染历史。
///
/// 模型列表也在这里自动维护：
/// - 面板出现、服务列表变了就预拉一遍（目录只拉缺的 / 过期的 / 失败的 / 换了端点的，
///   不会反复请求），打开模型菜单时已经有内容；
/// - 还没选模型的服务，列表一到就替它选上默认模型（`AgentModelDirectory.fillMissingModels`），
///   不必先去菜单里手选才能发第一条消息。
struct AgentSessionModifier: ViewModifier {
    let model: AssistantModel
    let safety: AgentSafety

    @Environment(\.modelContext) private var modelContext

    func body(content: Content) -> some View {
        content
            .onAppear {
                model.approvalMode = safety
                model.attach(context: modelContext)
            }
            .onChange(of: safety) { _, value in model.approvalMode = value }
            .onChange(of: model.providers.map(\.id), initial: true) { _, _ in
                prefetchModels()
            }
            .onChange(of: missingModelSignature, initial: true) { _, _ in
                AgentModelDirectory.fillMissingModels(model.providers)
            }
    }

    /// 预拉只拉有 Key 的服务（没 Key 拉也是「认证失败」）。服务列表还没灌进来（iOS 上它由
    /// 另一个 modifier 的 onAppear 注入，可能晚一拍）时什么都不做：`refresh` 会先
    /// `retainOnly` 当前列表，空列表等于把整份缓存清掉。
    private func prefetchModels() {
        guard !model.providers.isEmpty else { return }
        let keyed = model.providers.filter { ProviderManagement.hasKey($0) }
        guard !keyed.isEmpty else { return }
        AgentModelDirectory.catalog.refresh(keyed.map { AgentModelDirectory.source(for: $0) })
    }

    /// 还没选模型的服务各自拉到了几个模型：列表一到（或又多一个这样的服务）就变。
    private var missingModelSignature: [String] {
        model.providers.filter(\.model.isEmpty).map { provider in
            "\(provider.id.uuidString)|\(AgentModelDirectory.catalog.entry(for: provider.id)?.models.count ?? 0)"
        }
    }
}

extension View {
    /// 见 `AgentSessionModifier`。
    func agentSession(_ model: AssistantModel, safety: AgentSafety) -> some View {
        modifier(AgentSessionModifier(model: model, safety: safety))
    }
}
