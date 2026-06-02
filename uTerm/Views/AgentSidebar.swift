import SwiftUI

/// 工作区右 inspector：AI 助手。
struct AgentSidebar: View {
    let model: AssistantModel
    let serverContext: String
    @Binding var activeProviderIDString: String

    var body: some View {
        // 不覆盖 .background —— 与 SFTPSidebar 对称，让 macOS 26
        // NavigationSplitView 的 Liquid Glass inspector 材质透出，
        // 圆角/border 整圈才连贯。强制 bgPanel 会在 inspector 边缘
        // 截断玻璃效果（user issue 2026-05）。
        AssistantView(serverContext: serverContext,
                       model: model,
                       activeProviderIDString: $activeProviderIDString)
    }
}
