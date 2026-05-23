import SwiftUI

/// 工作区右 inspector：AI 助手。Spec 1 只重画样式，交互不动。
struct AgentSidebar: View {
    let model: AssistantModel
    let serverContext: String

    var body: some View {
        AssistantView(serverContext: serverContext, model: model)
            .background(AppTheme.Palette.bgPanel)
    }
}
