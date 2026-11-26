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
                    VStack(alignment: .leading, spacing: 5) {
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
