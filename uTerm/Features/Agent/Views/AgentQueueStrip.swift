#if os(macOS)
import AgentKit
import SwiftUI
import UDesignKit

/// 待发队列条带：聊天区与输入框之间，列出 Agent 忙碌时排进 `queuedMessages`、尚未发出的
/// 消息。工作区 Agent 面板与终端 Agent 共用 —— 终端窗口原先没挂它，输入框占位符说
/// 「输入会排队发送」，可排进去的消息哪儿都看不见。
///
/// 外观、交互、无障碍都在 DesignKit 的 `UDAgentQueueStrip`（uTable 用同一个），这里只把
/// `AssistantModel` 的队列接上去。
struct AgentQueueStrip: View {
    let model: AssistantModel
    /// 只在有排队消息时生效：队列为空时条带连同边距一起消失，不在输入区上方留空隙。
    var insets = EdgeInsets()

    var body: some View {
        if !model.queuedMessages.isEmpty {
            UDAgentQueueStrip(
                items: model.queuedMessages.map {
                    UDAgentQueueItem(id: $0.id, text: $0.text, sendsAtNextStep: $0.delivery == .nextStep)
                },
                onSendNow: model.sendQueuedAtNextStep,
                onEdit: model.loadQueuedForEditing,
                onRemove: model.removeQueued)
            .padding(insets)
        }
    }
}
#endif
