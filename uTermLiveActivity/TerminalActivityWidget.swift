import ActivityKit
import SwiftUI
import WidgetKit

/// 终端状态的实时活动：灵动岛（紧凑 / 最小 / 展开）与锁屏。
/// 内容全部来自 App（见 `TerminalActivityAttributes`），这里只负责排版。
struct TerminalActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TerminalActivityAttributes.self) { context in
            TerminalLockScreenView(state: context.displayState)
                .activityBackgroundTint(nil)
                .widgetURL(TerminalActivityAttributes.link(tab: context.state.rows.first?.id))
        } dynamicIsland: { context in
            let state = context.displayState
            let top = state.rows.first
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    TerminalGlyph(tone: top?.tone, paused: state.paused)
                        .font(.system(size: 22, weight: .semibold))
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if state.rows.count + state.overflow > 1 {
                        Text(verbatim: "\(state.rows.count + state.overflow)")
                            .font(.system(size: 15, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.trailing, 4)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(state.rows) { row in
                            Link(destination: TerminalActivityAttributes.link(tab: row.id)) {
                                TerminalRowView(row: row, paused: state.paused, compact: true)
                            }
                        }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    TerminalFooterView(state: state)
                }
            } compactLeading: {
                TerminalGlyph(tone: top?.tone, paused: state.paused)
            } compactTrailing: {
                if let top {
                    // 横屏时灵动岛竖着放、很窄：放不下字就只画状态图标。
                    ViewThatFits(in: .horizontal) {
                        Text(verbatim: top.shortStatus)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                            .fixedSize()
                        Image(systemName: top.tone.symbol)
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(state.paused ? .secondary : top.tone.color)
                }
            } minimal: {
                TerminalGlyph(tone: top?.tone, paused: state.paused)
            }
            .widgetURL(TerminalActivityAttributes.link(tab: top?.id))
            .keylineTint(top?.tone.color ?? .secondary)
        }
    }
}

// MARK: - 锁屏

private struct TerminalLockScreenView: View {
    let state: TerminalActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                TerminalGlyph(tone: state.rows.first?.tone, paused: state.paused)
                    .font(.system(size: 15, weight: .semibold))
                Text(verbatim: "uTerm").font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 0)
            }
            ForEach(state.rows) { row in
                Link(destination: TerminalActivityAttributes.link(tab: row.id)) {
                    TerminalRowView(row: row, paused: state.paused, compact: false)
                }
            }
            TerminalFooterView(state: state)
        }
        .padding(16)
    }
}

// MARK: - 部件

/// 一行：状态点、「Claude Code · 等待确认」、标签页标题 / 主机、运行时长。
private struct TerminalRowView: View {
    let row: TerminalActivityAttributes.Row
    let paused: Bool
    let compact: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(paused ? Color.secondary : row.tone.color)
                .frame(width: 8, height: 8)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: "\(row.program) · \(row.status)")
                    .font(.system(size: compact ? 14 : 15, weight: .semibold))
                    .lineLimit(1)
                Text(verbatim: subtitle)
                    .font(.system(size: compact ? 12 : 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if !paused, row.tone == .working {
                Text(timerInterval: row.since...Date.distantFuture, countsDown: false)
                    .font(.system(size: compact ? 12 : 13).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 64, alignment: .trailing)
            }
        }
        .opacity(paused ? 0.6 : 1)
    }

    private var subtitle: String {
        guard let host = row.host else { return row.title }
        return "\(row.title) — \(host)"
    }
}

/// 底行：「还有 N 个」与暂停 / 保持说明。
private struct TerminalFooterView: View {
    let state: TerminalActivityAttributes.ContentState

    var body: some View {
        if state.overflowText != nil || state.footer != nil {
            HStack(spacing: 4) {
                if let footer = state.footer {
                    Text(verbatim: footer)
                    if let until = state.keepUntil, until > Date.now {
                        Text(timerInterval: Date.now...until, countsDown: true)
                            .monospacedDigit()
                    }
                }
                Spacer(minLength: 0)
                if let text = state.overflowText {
                    Text(verbatim: text)
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }
}

/// 终端图标，按最需要处理的那行着色。
private struct TerminalGlyph: View {
    let tone: TerminalActivityAttributes.Tone?
    let paused: Bool

    var body: some View {
        Image(systemName: "apple.terminal.fill")
            .foregroundStyle(paused ? .secondary : (tone?.color ?? .secondary))
    }
}

extension TerminalActivityAttributes.Tone {
    /// 与 App 里标签页圆点同义：等人处理 = 橙，运行中 = 蓝，完成 = 绿，出错 = 红。
    /// 紧凑态放不下字时的图标。
    var symbol: String {
        switch self {
        case .attention: "exclamationmark.circle.fill"
        case .working: "ellipsis.circle.fill"
        case .done: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .attention: .orange
        case .working: .blue
        case .done: .green
        case .failed: .red
        }
    }
}

extension ActivityViewContext<TerminalActivityAttributes> {
    /// 过期了（App 没来得及推「已暂停」就被挂起）按已暂停画：计时停走、换底行。
    var displayState: TerminalActivityAttributes.ContentState {
        guard isStale, !state.paused else { return state }
        var state = state
        state.paused = true
        state.keepUntil = nil
        state.footer = state.pausedText
        return state
    }
}
