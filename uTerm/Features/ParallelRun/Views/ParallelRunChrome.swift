import UDesignKit
import SwiftUI

/// 并行执行窗口的 chrome：自绘标题栏、广播条、状态栏，及共享小件。
/// AI 紫 = `UD.aiAccent`；Shell 蓝/绿走 `UD.accent` / `UD.success`。

/// 命令块 / Shell 网格的「终端面」底色 —— 对齐设计稿 `--u-term-bg`：**暗夜 #08080a / 日间 #ffffff**
///（`u-window.jsx` DARK/LIGHT 两档）。**不能**用 `UD.terminal`（它日 / 夜都深，是真实 SwiftTerm
/// 终端用的）——否则日间得到一条「黑底」命令块，与白色日间主题格格不入、且字读不出（用户实测）。
/// 面随主题翻后，其上文字直接用 `UD.text`/`text3`/`text4`（深底亮字 / 白底深字）即两档都可读。
enum ParTermSurface {
    static let bg = UD.dyn(.hex(0x08080A), .hex(0xFFFFFF))
}

// MARK: - 标题栏

/// 38pt 自绘标题栏（与全工程其它窗口同高，红绿灯由 `WorkspaceWindowChrome` 居中到 38）：
/// 红绿灯让位 + （AI 时紫火花）命令名 + 并行徽标 + 右侧 Shell|AI 切换 + 重新运行 + 关闭。
struct ParallelRunTitleBar: View {
    let commandName: String
    let aiAssisted: Bool
    let total: Int
    @Binding var mode: ParallelViewMode
    let running: Bool
    let onRerun: () -> Void
    let onClose: () -> Void

    var body: some View {
        ZStack {
            HStack(spacing: 2) {
                Color.clear.frame(width: 68)   // 让位窗口红绿灯
                if aiAssisted {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12))
                        .foregroundStyle(UD.aiAccent)
                }
                Text(commandName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(UD.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // 纯展示，不参与命中测试：否则会截走标题栏空白处的双击（缩放）/ 拖动（见 WindowDragHandle）。
                    .allowsHitTesting(false)
                ParBadge(ai: mode == .ai, count: total)
                    .padding(.leading, 4)
                    .allowsHitTesting(false)
                Spacer(minLength: 8)

                ParModeToggle(mode: $mode)

                rerunButton
                closeButton
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 38)
        .frame(maxWidth: .infinity)
        .background(WindowDragHandle())
        .overlay(alignment: .bottom) { Rectangle().fill(UD.border).frame(height: 1) }
    }

    private var rerunButton: some View {
        Button(action: onRerun) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                Text("重新运行").font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(running ? UD.text4 : UD.text2)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(UD.fillFaint))
        }
        .buttonStyle(.plain)
        .disabled(running)
        .help("重新运行")
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(UD.text3)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("关闭")
    }
}

/// Shell | AI 视图切换。选中段填充：Shell = `UD.accent`，AI = `UD.aiAccent`（紫）。
/// 不用 `UDSegmented`——它选中段恒用 accent，无法按段着紫。
private struct ParModeToggle: View {
    @Binding var mode: ParallelViewMode

    var body: some View {
        HStack(spacing: 2) {
            tab(.shell, label: "Shell", systemImage: "terminal", tint: UD.accent)
            tab(.ai, label: "AI", systemImage: "sparkles", tint: UD.aiAccent)
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(UD.fillFaint))
    }

    private func tab(_ value: ParallelViewMode, label: String, systemImage: String, tint: Color) -> some View {
        let active = mode == value
        return Button {
            withAnimation(.easeOut(duration: 0.16)) { mode = value }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: systemImage).font(.system(size: 11, weight: .medium))
                Text(label).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(active ? Color.white : UD.text3)
            .padding(.horizontal, 11)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(active ? tint : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 广播条

/// 命令代码块（深底等宽 + 广播至 N 台）+ 聚合进度条 + 统计。
struct ParallelBroadcastBar: View {
    /// 广播文案：`isIntent` 为真时是自然语言意图（AI 命令无等效 shell），否则是 `$ command`。
    let text: String
    let isIntent: Bool
    let mode: ParallelViewMode
    let total: Int
    let doneCount: Int
    let okCount: Int
    let failedCount: Int
    let startedAt: Date
    let finishedAt: Date?

    private var tint: Color { mode == .ai ? UD.aiAccent : UD.accent }
    private var pct: Double { total == 0 ? 0 : Double(doneCount) / Double(total) }

    var body: some View {
        VStack(spacing: 9) {
            commandBlock
            HStack(spacing: 12) {
                progressTrack
                stats
            }
        }
        .padding(EdgeInsets(top: 11, leading: 16, bottom: 12, trailing: 16))
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(0.015))
        .overlay(alignment: .bottom) { Rectangle().fill(UD.border).frame(height: 1) }
    }

    private var commandBlock: some View {
        HStack(spacing: 9) {
            if isIntent {
                Image(systemName: "sparkles").font(.system(size: 12)).foregroundStyle(tint)
            } else {
                QCParallelIcon(size: 13, color: tint)
                Text("$").foregroundStyle(tint)
            }
            Text(text)
                .font(isIntent ? .system(size: 12.5) : .system(size: 12.5, design: .monospaced))
                .foregroundStyle(UD.text)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Text("广播至 \(total) 台").font(.system(size: 11)).foregroundStyle(UD.text4)
        }
        .font(.system(size: 12.5, design: .monospaced))
        .padding(.horizontal, 11)
        .frame(minHeight: 36)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(ParTermSurface.bg))
    }

    private var progressTrack: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(UD.fillMed)
                Capsule()
                    .fill(failedCount > 0
                          ? LinearGradient(colors: [tint, UD.warning], startPoint: .leading, endPoint: .trailing)
                          : LinearGradient(colors: [tint, tint], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(0, geo.size.width * pct))
                    .animation(.easeOut(duration: 0.35), value: pct)
            }
        }
        .frame(height: 6)
    }

    private var stats: some View {
        HStack(spacing: 12) {
            HStack(spacing: 0) {
                Text("完成 ").foregroundStyle(UD.text2)
                Text("\(doneCount)").foregroundStyle(UD.text)
                Text("/\(total)").foregroundStyle(UD.text3)
            }
            statDot(color: UD.success, text: "\(okCount) 成功")
            if failedCount > 0 { statDot(color: UD.danger, text: "\(failedCount) 失败") }
            TimelineView(.periodic(from: startedAt, by: 0.1)) { ctx in
                let end = finishedAt ?? ctx.date
                Text(String(format: "%.1fs", max(0, end.timeIntervalSince(startedAt))))
                    .foregroundStyle(UD.text4)
            }
        }
        .font(.system(size: 11.5, design: .monospaced))
        .fixedSize()
    }

    private func statDot(color: Color, text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).foregroundStyle(color)
        }
    }
}

// MARK: - 状态栏

struct ParallelStatusBar: View {
    let mode: ParallelViewMode
    let total: Int
    let doneCount: Int
    let failedCount: Int
    let allDone: Bool

    private var tint: Color { mode == .ai ? UD.aiAccent : UD.accent }

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                QCParallelIcon(size: 11, color: tint)
                Text(mode == .ai ? "并行 · AI 介入" : "并行广播").foregroundStyle(tint)
            }
            Text("\(total) 台").foregroundStyle(UD.text2)
            Text("完成 \(doneCount)/\(total)").foregroundStyle(UD.text3)
            if failedCount > 0 { Text("\(failedCount) 失败").foregroundStyle(UD.danger) }
            Spacer()
            Text(allDone ? "已完成" : "执行中").foregroundStyle(UD.text3)
            Text("UTF-8").foregroundStyle(UD.text3)
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(Self.clock(ctx.date)).foregroundStyle(UD.text4)
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 12)
        .frame(height: 28)
        .frame(maxWidth: .infinity)
        .background(UD.panel)
        .overlay(alignment: .top) { Rectangle().fill(UD.border).frame(height: 1) }
    }

    private static func clock(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute, .second], from: d)
        return String(format: "%02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }
}

// MARK: - 共享小件

/// 并行徽标：AI = 紫「并行 · AI 介入 · N 台」；Shell = 绿「并行执行 · N 台」。
struct ParBadge: View {
    let ai: Bool
    let count: Int

    private var tint: Color { ai ? UD.aiAccent : UD.success }

    var body: some View {
        HStack(spacing: 6) {
            QCParallelIcon(size: 11, color: tint)
            Text(ai ? "并行 · AI 介入 · \(count) 台" : "并行执行 · \(count) 台")
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(tint)
        .padding(.leading, 8)
        .padding(.trailing, 9)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(tint.opacity(0.14)))
        .fixedSize()
    }
}

/// AI 泳道开场 / 汇总用的紫色火花头像（圆角方块 + sparkles）。
struct ParAgentAvatar: View {
    var size: CGFloat = 26
    var body: some View {
        RoundedRectangle(cornerRadius: size * 8 / 30, style: .continuous)
            .fill(UD.aiAccent.opacity(0.15))
            .overlay(Image(systemName: "sparkles").font(.system(size: size * 0.46)).foregroundStyle(UD.aiAccent))
            .frame(width: size, height: size)
    }
}
