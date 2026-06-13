import SwiftUI

/// uTerm DesignKit 工具调用卡片 —— Agent 生成命令 / 等待审批的 Cursor 风格卡片
/// （设计稿 `workspace.jsx` 的 `ToolCall`，对话与状态 · Comms 家族）。
///
/// 三段式结构：
/// - 头部：命令提示符图标 + 标签（「运行命令」）+ 右侧状态点（绿=已完成 / 强调色=待确认）。
/// - 命令行：终端底 `$ <command>`（等宽、可选中、自动换行）。
/// - 落定后展示 `output`（≤110 高滚动）；待确认时展示「运行 ⌘↵ / 跳过」审批行。
///
/// 纯展示组件：只读 `UD` token + 普通值 / 闭包输入，不依赖任何 domain model。
/// 上下各留 8 的外边距，使其与上下文消息保持呼吸感（设计稿 `margin: 8px 0`）。
struct UDToolCall: View {
    /// 卡片状态。`pending` 待用户审批；`done` 已执行并可附带输出。
    enum Status: Equatable {
        case pending
        case running
        case done(output: String? = nil)
    }

    /// 头部标签（如「运行命令」「运行命令 · 需要确认」）。
    var label: String = "运行命令"
    /// 待执行 / 已执行的命令文本。
    let command: String
    var status: Status = .pending
    /// 待确认态审批是否可点。默认 `true`（纯展示/Gallery 场景）。
    /// 接入状态机时由调用方仅在「真正等待批准」时置 `true`——流式仍在进行（卡片虽已
    /// 渲染成 pending）时置 `false`，避免用户在流未结束时点「运行」触发状态机重入。
    var approvalEnabled: Bool = true
    /// 待确认态「运行」回调。
    var onRun: () -> Void = {}
    /// 待确认态「跳过」回调。
    var onSkip: () -> Void = {}

    private var isDone: Bool {
        if case .done = status { return true }
        return false
    }

    private var isRunning: Bool {
        if case .running = status { return true }
        return false
    }

    /// 审批按钮是否禁用：执行中，或调用方尚未进入「等待批准」（流式仍在飞行）。
    private var approvalsDisabled: Bool { isRunning || !approvalEnabled }

    private var statusText: String {
        switch status {
        case .pending: return "待确认"
        case .running: return "执行中"
        case .done: return "已完成"
        }
    }

    private var statusColor: Color {
        isDone ? UD.success : UD.accent
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            commandRow
            if case let .done(output) = status, let output, !output.isEmpty {
                outputRow(output)
            }
            if case .pending = status {
                actions
            } else if case .running = status {
                actions
            }
        }
        .background(UD.dyn(.white(0.025), .black(0.042)))
        .clipShape(RoundedRectangle(cornerRadius: UD.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: UD.Radius.md, style: .continuous)
                .strokeBorder(UD.border, lineWidth: 1)
        )
        .padding(.vertical, 8)
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 7) {
            UDCommandGlyph()
                .stroke(UD.text3, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                .frame(width: 12, height: 12)

            Text(label)
                .font(UD.font(11))
                .foregroundStyle(UD.text2)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 4) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 5, height: 5)
                Text(statusText)
                    .font(UD.font(10))
                    .foregroundStyle(isDone ? UD.success : UD.text4)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Rectangle().fill(UD.border).frame(height: 1)
        }
    }

    // MARK: - 命令行

    private var commandRow: some View {
        HStack(alignment: .top, spacing: 7) {
            Text("$")
                .foregroundStyle(UD.accent)
            Text(command)
                // 命令落在 `UD.terminal`（始终近黑）上 —— 用 terminalText 浅色，
                // 否则日间 text2 深灰会与深底糊在一起（不可读）。
                .foregroundStyle(UD.terminalText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .font(UD.mono(11.5))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(UD.terminal)
    }

    // MARK: - 输出（已完成）

    private func outputRow(_ output: String) -> some View {
        ScrollView {
            Text(output)
                .font(UD.mono(11))
                .foregroundStyle(UD.text3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .frame(maxHeight: 110)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .overlay(alignment: .top) {
            Rectangle().fill(UD.border).frame(height: 1)
        }
    }

    // MARK: - 审批行（待确认）

    private var actions: some View {
        HStack(spacing: 7) {
            Button(action: onRun) {
                HStack(spacing: 6) {
                    if isRunning {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.62)
                            .frame(width: 12, height: 12)
                        Text("运行中")
                            .font(UD.font(11.5, weight: .semibold))
                            .foregroundStyle(UD.text3)
                    } else {
                        Text("运行")
                            .font(UD.font(11.5, weight: .semibold))
                            .foregroundStyle(approvalsDisabled ? UD.text4 : UD.text)
                        UDKbd("⌘↵")
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: UD.Radius.sm, style: .continuous)
                        .fill(UD.accent.opacity(approvalsDisabled ? 0.06 : 0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: UD.Radius.sm, style: .continuous)
                        .strokeBorder(UD.accent.opacity(approvalsDisabled ? 0.2 : 0.4), lineWidth: 1)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(approvalsDisabled)

            Button(action: onSkip) {
                Text("跳过")
                    .font(UD.font(11.5))
                    .foregroundStyle(approvalsDisabled ? UD.text4 : UD.text3)
                    .padding(.horizontal, 12)
                    .frame(height: 26)
                    .overlay(
                        RoundedRectangle(cornerRadius: UD.Radius.sm, style: .continuous)
                            .strokeBorder(UD.border, lineWidth: 1)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(approvalsDisabled)

            Spacer(minLength: 0)

            Text(isRunning ? "命令执行中" : "运行前会请求确认")
                .font(UD.font(10))
                .foregroundStyle(UD.text4)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .overlay(alignment: .top) {
            Rectangle().fill(UD.border).frame(height: 1)
        }
    }
}

// MARK: - 命令提示符字形

/// `>‾` 形命令提示符字形（设计稿 14×14 viewBox 双笔画：`>` 折线 + 下划线）。
private struct UDCommandGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 14
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * s, y: rect.minY + y * s)
        }
        var path = Path()
        path.move(to: p(3, 3.5))
        path.addLine(to: p(6, 7))
        path.addLine(to: p(3, 10.5))
        path.move(to: p(7.5, 10.5))
        path.addLine(to: p(11.5, 10.5))
        return path
    }
}

// MARK: - Preview

#Preview {
    VStack(alignment: .leading, spacing: 8) {
        UDToolCall(
            command: "grep ' 502 ' /var/log/nginx/access.log | awk '{print $4}' | cut -d: -f2 | sort | uniq -c",
            status: .done(output: "     2 09\n     3 10\n    47 14\n    51 15\n     4 16")
        )

        UDToolCall(
            label: "运行命令 · 需要确认",
            command: "for i in $(seq 1 20); do curl -s -o /dev/null -w \"%{http_code} %{time_total}\\n\" http://127.0.0.1:8080/health; done",
            status: .pending
        )

        UDToolCall(
            label: "运行命令 · 执行中",
            command: "tail -f /var/log/nginx/error.log",
            status: .running
        )
    }
    .frame(width: 300)
    .padding(24)
    .background(UD.bg)
}
