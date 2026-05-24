import SwiftUI

/// 工作区右 inspector：AI 助手。
struct AgentSidebar: View {
    let model: AssistantModel
    let serverContext: String
    @Binding var activeProviderIDString: String

    var body: some View {
        AssistantView(serverContext: serverContext,
                       model: model,
                       activeProviderIDString: $activeProviderIDString)
            .background(AppTheme.Palette.bgPanel)
    }
}
