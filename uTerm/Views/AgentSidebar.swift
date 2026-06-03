import SwiftUI

/// 工作区右 inspector：AI 助手。
struct AgentSidebar: View {
    let model: AssistantModel
    let serverContext: String
    var serverName: String = ""
    @Binding var activeProviderIDString: String

    var body: some View {
        // 铺 WS.bg 实色 —— 与 SFTPSidebar 对称，主动切断 NavigationSplitView 的
        // Liquid Glass inspector 材质（去玻璃改造）。窗口已钉 .darkAqua。
        AssistantView(serverContext: serverContext,
                       serverName: serverName,
                       model: model,
                       activeProviderIDString: $activeProviderIDString)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(WS.bg)
    }
}
