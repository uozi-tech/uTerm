import SwiftUI
import UDesignKit

/// Shared by the workspace Agent and the terminal Agent.
struct AgentStopControl: View {
    @Bindable var model: AssistantModel

    var body: some View {
        if model.canStop || model.turnWasStopped {
            HStack(spacing: 8) {
                if model.turnWasStopped {
                    Text(model.state == .running
                         ? "已停止后续步骤，已下发命令仍在运行"
                         : "已停止")
                        .font(.caption)
                        .foregroundStyle(UD.text3)
                }
                Spacer(minLength: 0)
                if model.canStop {
                    Button(action: model.stop) {
                        Label("停止对话", systemImage: "stop.fill")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("停止对话")
                    .help("停止生成和审批，取消待执行命令；已下发命令继续回收结果")
                }
            }
        }
    }
}
