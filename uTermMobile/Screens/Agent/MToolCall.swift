import SwiftUI

/// Agent 命令卡片（移动端）：Agent 生成命令 / 等待审批 / 已执行的卡片。
/// 镜像 macOS `UDToolCall`（三段式：头部 → `$ command` → 输出 / 审批行），改用 `M`
/// token + 触屏尺寸，去掉 macOS 的 ⌘↵ 键盘提示。
struct MToolCall: View {
    enum Status: Equatable {
        case pending
        case running
        case done(output: String? = nil)
    }

    var label: String = "运行命令"
    let command: String
    var status: Status = .pending
    /// 待确认态审批是否可点：仅在状态机真正「等待批准」时为 true——流式仍在进行（卡片虽已
    /// 渲染成 pending）时为 false，避免用户在流未结束时点「运行」触发状态机重入。
    var approvalEnabled: Bool = true
    var onRun: () -> Void = {}
    var onSkip: () -> Void = {}

    private var isDone: Bool { if case .done = status { return true }; return false }
    private var isRunning: Bool { if case .running = status { return true }; return false }
    /// 审批按钮禁用：执行中，或调用方尚未进入「等待批准」。
    private var approvalsDisabled: Bool { isRunning || !approvalEnabled }

    private var statusText: String {
        switch status {
        case .pending: return "待确认"
        case .running: return "运行中"
        case .done:    return "已完成"
        }
    }
    private var statusColor: Color { isDone ? M.success : M.accent }
    /// 与底部「运行 / 跳过」钮同心：钮距卡片底边 8pt。
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: MRadius.concentric(MRadius.sm, inset: 8), style: .continuous)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            commandRow
            if case let .done(output) = status, let output, !output.isEmpty {
                outputRow(output)
            }
            if case .pending = status { actions } else if case .running = status { actions }
        }
        .background(shape.fill(M.panel))
        .clipShape(shape)
        .overlay(shape.strokeBorder(M.border, lineWidth: 1))
        .padding(.vertical, 6)
    }

    private var header: some View {
        HStack(spacing: 7) {
            MIcon(name: "cmd", size: 12, color: M.text3)
            Text(label)
                .font(M.sans(11.5)).foregroundStyle(M.text2).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) {
                Circle().fill(statusColor).frame(width: 5, height: 5)
                Text(statusText).font(M.sans(10.5)).foregroundStyle(isDone ? M.success : M.text4)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(M.divider).frame(height: 1) }
    }

    private var commandRow: some View {
        HStack(alignment: .top, spacing: 7) {
            Text("$").foregroundStyle(M.accent)
            Text(command)
                .foregroundStyle(M.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .font(M.mono(12))
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        // 卡片内不再垫一块更亮的底：与头部之间已有 hairline（「线或底色差，二选一」）。
    }

    private func outputRow(_ output: String) -> some View {
        ScrollView {
            Text(output)
                .font(M.mono(11)).foregroundStyle(M.text2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .frame(maxHeight: 160)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .overlay(alignment: .top) { Rectangle().fill(M.divider).frame(height: 1) }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button(action: onRun) {
                HStack(spacing: 6) {
                    if isRunning {
                        ProgressView().controlSize(.small).scaleEffect(0.8).frame(width: 14, height: 14)
                        Text("运行中").font(M.sans(12.5, weight: .semibold)).foregroundStyle(M.text3)
                    } else {
                        MIcon(name: "run", size: 11, color: approvalsDisabled ? M.text4 : M.accent)
                        Text("运行").font(M.sans(12.5, weight: .semibold))
                            .foregroundStyle(approvalsDisabled ? M.text4 : M.accent)
                    }
                }
                .padding(.horizontal, 14).frame(height: 34)
                .background(RoundedRectangle(cornerRadius: MRadius.sm)
                    .fill(M.accent.opacity(approvalsDisabled ? 0.08 : 0.14)))
                .contentShape(Rectangle())
            }
            .buttonStyle(MPressStyle())
            .disabled(approvalsDisabled)

            Button(action: onSkip) {
                Text("跳过").font(M.sans(12.5)).foregroundStyle(approvalsDisabled ? M.text4 : M.text3)
                    .padding(.horizontal, 14).frame(height: 34)
                    .background(RoundedRectangle(cornerRadius: MRadius.sm).fill(M.button))
                    .contentShape(Rectangle())
            }
            .buttonStyle(MPressStyle())
            .disabled(approvalsDisabled)

            Spacer(minLength: 0)

            Text(isRunning ? "命令运行中" : "运行前会请求确认")
                .font(M.sans(10)).foregroundStyle(M.text4)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .overlay(alignment: .top) { Rectangle().fill(M.divider).frame(height: 1) }
    }
}
