#if os(macOS)
import SwiftUI
import UDesignKit

/// 待发队列条带：聊天区与输入框之间，列出 Agent 忙碌时排进 `queuedMessages`、尚未发出的
/// 消息。工作区 Agent 面板与终端 Agent 共用 —— 终端窗口原先没挂它，输入框占位符说
/// 「输入会排队发送」，可排进去的消息哪儿都看不见。
struct AgentQueueStrip: View {
    let model: AssistantModel
    /// 只在有排队消息时生效：队列为空时条带连同边距一起消失，不在输入区上方留空隙。
    var insets = EdgeInsets()

    var body: some View {
        if !model.queuedMessages.isEmpty {
            VStack(spacing: 4) {
                ForEach(model.queuedMessages) { row($0) }
            }
            .padding(insets)
        }
    }

    private func row(_ item: QueuedMessage) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "clock")
                .font(.system(size: 10))
                .foregroundStyle(UD.text4)
            Text(item.text)
                .font(.system(size: 12))
                .foregroundStyle(UD.text3)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { model.loadQueuedForEditing(id: item.id) } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 10)).foregroundStyle(UD.text4)
                    .frame(width: 20, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("编辑").help("编辑")
            Button { model.removeQueued(id: item.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10)).foregroundStyle(UD.text4)
                    .frame(width: 20, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("移除").help("移除")
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(UD.fillSoft))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(UD.border, style: StrokeStyle(lineWidth: 1, dash: [3]))
        )
        .contentShape(Rectangle())
        .onTapGesture { model.loadQueuedForEditing(id: item.id) }
        // 整行可点（= 载入编辑），但 `onTapGesture` 对 AX 完全不可见：
        // 合成一个元素，显式给 label / isButton / 默认动作，并把两个图标钮的
        // 语义保留成命名动作，读屏与全键盘控制才按得动。
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("排队消息：\(item.text)")
        .accessibilityHint("点按载入到输入框编辑")
        .accessibilityAction { model.loadQueuedForEditing(id: item.id) }
        .accessibilityAction(named: "编辑") { model.loadQueuedForEditing(id: item.id) }
        .accessibilityAction(named: "移除") { model.removeQueued(id: item.id) }
    }
}
#endif
