import SwiftUI
import UDesignKit

/// iPhone Duo 横握时状态栏那一列（宽约 84pt）里的账号额度：Agent / 分屏开关下面，每种工具一块——图标，下面一个圆环
/// （照系统的容量式仪表 `accessoryCircularCapacity`：底环、圆头的进度弧、正中写用了几成），环下写时间窗的名字。
/// 每种工具放最紧的三个时间窗（`AgentAccountLimits.compact`，如 5 小时、每周、Fable），颜色按程度蓝 / 黄 / 红（`AgentUsageLevel`）。
/// 一列窄，细条在这里读不出长短，圆环读得出。点一下弹出全部明细（同侧栏底部那一行点开的）。
/// 上下文在最上面（见 body）。数据与侧栏底部同一份（`AgentHistoryModel.accountLimits`）；列表照旧每分钟重读状态栏的数据。
struct WorkspaceSideAccountLimits: View {
    let history: AgentHistoryModel
    let width: CGFloat

    @State private var showsDetail = false

    var body: some View {
        let rows = history.accountLimits()
        VStack(spacing: 16) {
            // 先放正在看的会话的上下文（知道窗口多大画占了几成，不知道只写 token 数），额度排在后面：Duo 合上横握时
            // 这一列只有约 466pt 高，几种工具的额度一多，排在最后的会被挤出屏幕（上下文比额度常看）。
            if let usage = history.currentContextUsage {
                VStack(spacing: 4) {
                    WorkspaceQuotaRing(usedPercent: usage.contextFraction.map { $0 * 100 },
                                       level: usage.contextFraction.map { AgentUsageLevel.of(percent: $0 * 100) } ?? .normal,
                                       text: usage.contextFraction == nil
                                           ? AgentHistoryText.tokenCount(usage.contextTokens) : nil)
                    Text(AgentHistoryText.usageContext)
                        .font(M.sans(10)).foregroundStyle(M.text3)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    // 用了多少 / 窗口多大（不知道窗口时圆环里已经写了用了多少）。
                    if let window = usage.contextWindow {
                        Text(verbatim: AgentHistoryText.tokenCount(usage.contextTokens) + "/" + AgentHistoryText.tokenCount(window))
                            .font(M.mono(9.5)).foregroundStyle(M.text3)
                            .lineLimit(1).minimumScaleFactor(0.6)
                            .padding(.horizontal, 4)
                    }
                }
                .frame(width: width)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(AgentHistoryText.usageBadge(usage)))
            }
            if !rows.isEmpty { limits(rows) }
        }
    }

    private func limits(_ rows: [AgentAccountLimits]) -> some View {
            Button { showsDetail.toggle() } label: {
                VStack(spacing: 16) {
                    ForEach(rows, id: \.tool) { row in
                        VStack(spacing: 8) {
                            AgentHistoryToolBadge(tool: row.tool, size: 16)
                            ForEach(Array(row.compact.enumerated()), id: \.offset) { _, window in
                                VStack(spacing: 4) {
                                    WorkspaceQuotaRing(usedPercent: window.usedPercent, level: AgentUsageLevel.of(window))
                                    Text(AgentHistoryText.rateLimitShortName(window))
                                        .font(M.sans(10)).foregroundStyle(M.text3)
                                        .lineLimit(1).minimumScaleFactor(0.7)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .frame(width: width)
                .contentShape(Rectangle())
            }
            .buttonStyle(MPressStyle())
            .accessibilityLabel(Text(rows.map { AgentHistoryText.accountLimitsTitle($0.tool) }.joined(separator: ", ")))
            .popover(isPresented: $showsDetail) {
                WorkspaceAccountLimitsPopover(rows: rows)
                    .presentationCompactAdaptation(.popover)
            }
    }
}

/// 一个圆环（时间窗的额度、会话的上下文）：从 12 点顺时针填到用了几成，正中写数字；颜色按程度：正常是强调色，
/// 快满了黄、满了红（`AgentUsageLevel`）。不知道占了几成（上下文窗口多大不知道）时只画底环，正中写 `text`。
private struct WorkspaceQuotaRing: View {
    let usedPercent: Double?
    var level: AgentUsageLevel = .normal
    var text: String? = nil
    @Environment(\.mAccent) private var accent

    private static let size: CGFloat = 40
    private static let lineWidth: CGFloat = 4

    var body: some View {
        let percent = usedPercent ?? 0
        let fraction = min(1, max(0, percent / 100))
        let tint = level == .normal ? accent : level.color
        ZStack {
            Circle().stroke(UD.fillSoft, lineWidth: Self.lineWidth)
            if usedPercent != nil {
                Circle().trim(from: 0, to: fraction)
                    .stroke(tint, style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Text(verbatim: text ?? "\(Int(percent.rounded()))")
                .font(M.mono(text == nil ? 12 : 9.5, weight: .semibold))
                .foregroundStyle(level == .normal ? M.text : level.color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, Self.lineWidth + 1)
        }
        .padding(Self.lineWidth / 2)
        .frame(width: Self.size, height: Self.size)
    }
}

/// 点额度弹出的明细。按内容的高度要（`idealHeight`），放不下时（Duo 横握、键盘弹起，屏幕顶和键盘之间只剩一点）系统把
/// 弹出框收矮，内容在里面滚，不再被顶边切掉、被键盘盖住（实机反馈）。
private struct WorkspaceAccountLimitsPopover: View {
    let rows: [AgentAccountLimits]
    @State private var contentHeight: CGFloat?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows, id: \.tool) { row in
                    AgentAccountLimitsDetail(row: row)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(idealHeight: contentHeight)
    }
}
