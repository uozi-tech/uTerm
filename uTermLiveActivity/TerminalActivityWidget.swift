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
                    TerminalHeadline(state: state, size: 15)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(state.rows) { row in
                            Link(destination: TerminalActivityAttributes.link(tab: row.id)) {
                                TerminalRowView(row: row, state: state, compact: true)
                            }
                        }
                        TerminalFooterView(state: state)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                TerminalGlyph(tone: top?.tone, paused: state.paused)
            } compactTrailing: {
                // 只放终端个数：状态看左边图标的颜色，展开看详情。数字在灵动岛竖着放（Duo 横屏）时也放得下。
                Text(verbatim: "\(state.rows.count + state.overflow)")
                    .font(.system(size: 15, weight: .heavy).monospacedDigit())
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(state.paused ? .secondary : (top?.tone.color ?? .secondary))
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TerminalGlyph(tone: state.rows.first?.tone, paused: state.paused)
                    .font(.system(size: 17, weight: .semibold))
                TerminalHeadline(state: state, size: 16)
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(state.rows) { row in
                    Link(destination: TerminalActivityAttributes.link(tab: row.id)) {
                        TerminalRowView(row: row, state: state, compact: false)
                    }
                }
            }
            TerminalFooterView(state: state)
        }
        .padding(16)
    }
}

// MARK: - 部件

/// 标题行：各行共有的「Claude Code · 运行中」，后面跟共有的主机（淡色）。什么都不共有时写 uTerm。
private struct TerminalHeadline: View {
    let state: TerminalActivityAttributes.ContentState
    let size: CGFloat

    var body: some View {
        let parts = [state.sharedProgram, state.sharedStatus].compactMap(\.self)
        let headline = parts.isEmpty ? "uTerm" : parts.joined(separator: " · ")
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: headline)
                .font(.system(size: size, weight: .semibold))
                .layoutPriority(1)
            Spacer(minLength: 0)
            if let host = state.sharedHost {
                Text(verbatim: host)
                    .font(.system(size: size - 3))
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
    }
}

/// 一行：状态点 + 标签页标题，右边是运行时长（运行中）或短状态（等人 / 完成 / 出错）；
/// 第二行只写标题行里没提到的：程序、运行中的状态、主机。全提到标题行了就只有一行。
private struct TerminalRowView: View {
    let row: TerminalActivityAttributes.Row
    let state: TerminalActivityAttributes.ContentState
    let compact: Bool

    private var paused: Bool { state.paused }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(paused ? Color.secondary : row.tone.color)
                .frame(width: 8, height: 8)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: row.title)
                    .font(.system(size: compact ? 14 : 15, weight: .semibold))
                    .lineLimit(1)
                if let detail {
                    Text(verbatim: detail)
                        .font(.system(size: compact ? 12 : 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            trailing
                .font(.system(size: compact ? 12 : 13, weight: .medium).monospacedDigit())
        }
        .opacity(paused ? 0.6 : 1)
    }

    @ViewBuilder private var trailing: some View {
        if row.tone == .working {
            if !paused {
                Text(timerInterval: row.since...Date.distantFuture, countsDown: false)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 64, alignment: .trailing)
            }
        } else if state.sharedStatus == nil {
            Text(verbatim: row.shortStatus)
                .foregroundStyle(paused ? Color.secondary : row.tone.color)
                .lineLimit(1)
                .fixedSize()
        }
    }

    private var detail: String? {
        var parts: [String] = []
        if state.sharedProgram == nil { parts.append(row.program) }
        // 不是运行中的状态写在右边了；运行中右边是计时，状态写在这里。
        if state.sharedStatus == nil, row.tone == .working { parts.append(row.status) }
        if state.sharedHost == nil, let host = row.host { parts.append(host) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
