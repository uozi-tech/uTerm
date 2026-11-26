import SwiftUI

// 实时活动的视图。和 `TerminalActivityAttributes` 一样放在共享目录：组件扩展用它画，
// App 的测试用它量尺寸（锁屏的实时活动最高约 160pt，超出的部分系统居中裁掉，见 `TerminalLockScreenView.usesTwoLineRows`）。

// MARK: - 锁屏

struct TerminalLockScreenView: View {
    let state: TerminalActivityAttributes.ContentState

    var body: some View {
        let twoLine = Self.usesTwoLineRows(state)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TerminalGlyph(tone: state.rows.first?.tone, paused: state.paused)
                    .font(.system(size: 17, weight: .semibold))
                TerminalHeadline(state: state, size: 16)
            }
            VStack(alignment: .leading, spacing: twoLine ? 8 : 6) {
                ForEach(state.rows) { row in
                    Link(destination: TerminalActivityAttributes.link(tab: row.id)) {
                        TerminalRowView(row: row, state: state, compact: !twoLine)
                    }
                }
            }
            TerminalFooterView(state: state)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    /// 锁屏的实时活动最高约 160pt，超出的部分系统居中裁掉（标题行和底行各切一半）。
    /// 一行两行字（标题 + 说明）约 35pt：只在两行以内、且没有底行，或者只有一行时这么排；
    /// 再多就和展开的灵动岛一样，每个终端只占一行，说明跟在标题后面。
    static func usesTwoLineRows(_ state: TerminalActivityAttributes.ContentState) -> Bool {
        let hasFooter = state.overflowText != nil || state.footer != nil
        return state.rows.count + (hasFooter ? 1 : 0) <= 2
    }
}

// MARK: - 部件

/// 标题行：各行共有的「Claude Code · 运行中」，后面跟共有的主机（淡色）。什么都不共有时写 uTerm。
struct TerminalHeadline: View {
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
/// 展开的灵动岛（`compact`）里这些跟在标题后面、同一行。
struct TerminalRowView: View {
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
            if compact {
                // 展开的灵动岛与锁屏都有固定的最大高度：标题行加三行两行字的会把第三行切掉一半，这里每行只占一行，
                // 程序 / 主机跟在标题后面（放不下先截它们）。锁屏什么时候这么排见 `TerminalLockScreenView.usesTwoLineRows`。
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: row.title)
                        .font(.system(size: 14, weight: .semibold))
                        .layoutPriority(1)
                    if let detail {
                        Text(verbatim: detail)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: row.title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    if let detail {
                        Text(verbatim: detail)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
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
struct TerminalFooterView: View {
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
struct TerminalGlyph: View {
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
