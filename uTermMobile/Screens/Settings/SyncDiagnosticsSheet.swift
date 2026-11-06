import UDesignKit
import SwiftUI
import UIKit

/// 同步诊断弹窗：展示 CloudKit 最近事件（环形缓冲，新→旧）+ 复制日志。
/// 排版与文案和 macOS 设置 · 同步的「查看事件…」弹窗共用 `SyncDiagnosticsPresentation`。
struct SyncDiagnosticsSheet: View {
    let sync: CloudKitSyncMonitor
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(SyncDiagnosticsPresentation.title).font(M.sans(17, weight: .semibold)).foregroundStyle(M.text)
                Spacer()
                Button("完成") { dismiss() }
                    .font(M.sans(15)).foregroundStyle(M.accent)
            }
            // 头部与底部按钮不在滚动内容里，`mSheetContentMargins` 管不到，直接按弹窗边距排
            .padding(.horizontal, MSheetMetrics.contentInset).padding(.top, 18).padding(.bottom, 14)
            Rectangle().fill(M.divider).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    let rows = SyncDiagnosticsPresentation.rows(sync.recentEvents)
                    if rows.isEmpty {
                        Text(SyncDiagnosticsPresentation.emptyMessage)
                            .font(M.sans(13)).foregroundStyle(M.text4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 24)
                    } else {
                        ForEach(rows) { e in
                            HStack(alignment: .top, spacing: 10) {
                                Text(e.time)
                                    .font(M.mono(11)).foregroundStyle(M.text4)
                                    .frame(width: 62, alignment: .leading)
                                Text(e.text).font(M.mono(12)).foregroundStyle(M.text2)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }

            MBtn(title: SyncDiagnosticsPresentation.copyButtonTitle, kind: .secondary, full: true, height: 48) {
                UIPasteboard.general.string = sync.exportText()
            }
            .padding(.horizontal, MSheetMetrics.contentInset).padding(.vertical, 16)
        }
        .presentationBackground(M.panel)
        .presentationDetents([.medium, .large])
    }
}
