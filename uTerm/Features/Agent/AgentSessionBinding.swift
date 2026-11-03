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
    }
}

extension View {
    /// 见 `AgentSessionModifier`。
    func agentSession(_ model: AssistantModel, safety: AgentSafety) -> some View {
        modifier(AgentSessionModifier(model: model, safety: safety))
    }
}
