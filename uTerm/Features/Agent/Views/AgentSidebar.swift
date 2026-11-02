import UDesignKit
import SwiftUI

/// 工作区右 inspector：AI 助手。
struct AgentSidebar: View {
    let model: AssistantModel
    let serverContext: String
    var serverName: String = ""
    @Binding var activeProviderIDString: String

    var body: some View {
        // 分区方案 v3.2 第 6 条：Agent 栏并进主内容卡成为右栏，与中栏同为卡面色
        // （`UD.panel`），之间只隔一条 1pt 竖线；不再有自己的圆角 / 轮廓。
        AssistantView(serverContext: serverContext,
                       serverName: serverName,
                       model: model,
                       activeProviderIDString: $activeProviderIDString)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(UD.panel)
    }
}
