import SwiftUI

/// iPhone Duo 横握时状态栏那一列（宽约 84pt）里的账号额度：Agent / 分屏开关下面，每种工具一块——图标，
/// 下面每个时间窗一行名字、一根细条、用了几成。点一下弹出全部明细（同侧栏底部那一行点开的）。
/// 数据与侧栏底部同一份（`AgentHistoryModel.accountLimits`）；列表照旧每分钟重读状态栏的数据。
struct WorkspaceSideAccountLimits: View {
    let history: AgentHistoryModel
    let width: CGFloat

    @State private var showsDetail = false

    var body: some View {
        let rows = history.accountLimits()
        if !rows.isEmpty {
            Button { showsDetail.toggle() } label: {
                VStack(spacing: 12) {
                    ForEach(rows, id: \.tool) { row in
                        VStack(spacing: 5) {
                            AgentHistoryToolBadge(tool: row.tool, size: 16)
                            ForEach(Array(row.windows.prefix(2).enumerated()), id: \.offset) { _, window in
                                VStack(spacing: 2) {
                                    Text(AgentHistoryText.rateLimitWindow(window))
                                        .font(M.sans(10)).foregroundStyle(M.text3)
                                        .lineLimit(1).minimumScaleFactor(0.7)
                                    AgentRateLimitBar(usedPercent: window.usedPercent)
                                        .frame(height: 3)
                                    Text(verbatim: "\(Int(window.usedPercent.rounded()))%")
                                        .font(M.mono(11, weight: .medium))
                                        .foregroundStyle(window.usedPercent >= 90 ? M.warning : M.text2)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .frame(width: width)
                .contentShape(Rectangle())
            }
            .buttonStyle(MPressStyle())
            .accessibilityLabel(Text(rows.map { AgentHistoryText.accountLimitsTitle($0.tool) }.joined(separator: ", ")))
            .popover(isPresented: $showsDetail) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows, id: \.tool) { row in
                        AgentAccountLimitsDetail(row: row)
                    }
                }
                .presentationCompactAdaptation(.popover)
            }
        }
    }
}
