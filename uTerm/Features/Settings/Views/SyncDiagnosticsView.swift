import UDesignKit
import SwiftUI
import AppKit

/// 设置 · 同步 →「查看事件…」弹出的同步诊断：CloudKit 最近事件（新→旧）+ 复制日志。
/// 排版与文案和 iOS `SyncDiagnosticsSheet` 共用 `SyncDiagnosticsPresentation`；
/// 更完整的历史在 Console（设置 · 诊断 →「显示日志」）。
struct SyncDiagnosticsView: View {
    let sync: CloudKitSyncMonitor
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let rows = SyncDiagnosticsPresentation.rows(sync.recentEvents)
        VStack(spacing: 0) {
            HStack {
                Text(SyncDiagnosticsPresentation.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(UD.text)
                Spacer()
                UDCountBadge(rows.count)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)
            Rectangle().fill(UD.border).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if rows.isEmpty {
                        SettingsEmptyRow(symbol: "clock.arrow.circlepath",
                                         text: SyncDiagnosticsPresentation.emptyMessage)
                    } else {
                        // 事件最多 80 条，按设置页卡片的样式手画分隔线（时间列之后对齐）。
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            if index > 0 {
                                Rectangle().fill(UD.border).frame(height: 1)
                                    .padding(.leading, SettingsMetrics.rowInset)
                            }
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(row.time)
                                    .font(UD.mono(11))
                                    .foregroundStyle(UD.text3)
                                    .frame(width: 62, alignment: .leading)
                                Text(row.text)
                                    .font(UD.mono(11.5))
                                    .foregroundStyle(UD.text)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, SettingsMetrics.rowInset)
                            .padding(.vertical, 8)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous)
                    .fill(UD.card))
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
            .frame(maxHeight: .infinity)
            .background(UD.pageBg)

            Rectangle().fill(UD.border).frame(height: 1)
            HStack(spacing: 8) {
                UDButton(title: SyncDiagnosticsPresentation.copyButtonTitle, style: .secondary,
                         systemImage: "doc.on.doc") {
                    let board = NSPasteboard.general
                    board.clearContents()
                    board.setString(sync.exportText(), forType: .string)
                }
                Spacer()
                UDButton(title: "完成", style: .primary) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 520, height: 420)
        .background(UD.bg)
        .onExitCommand { dismiss() }
    }
}
