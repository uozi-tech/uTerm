import UDesignKit
import SwiftUI
import UIKit

/// 同步诊断弹窗：展示 CloudKit 最近事件（环形缓冲，新→旧）+ 复制日志。
/// iOS 无 Console，故在 app 内提供——对照 macOS「诊断 › 显示日志」的 Console 入口。
struct SyncDiagnosticsSheet: View {
    let sync: CloudKitSyncMonitor
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("同步诊断").font(M.sans(17, weight: .semibold)).foregroundStyle(M.text)
                Spacer()
                Button("完成") { dismiss() }
                    .font(M.sans(15)).foregroundStyle(M.accent)
            }
            // 头部与底部按钮不在滚动内容里，`mSheetContentMargins` 管不到，直接按弹窗边距排
            .padding(.horizontal, MSheetMetrics.contentInset).padding(.top, 18).padding(.bottom, 14)
            Rectangle().fill(M.divider).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if sync.recentEvents.isEmpty {
                        Text("暂无同步事件。保持 app 前台、已登录 iCloud 后，setup / import / export 事件会出现在这里。")
                            .font(M.sans(13)).foregroundStyle(M.text4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 24)
                    } else {
                        ForEach(sync.recentEvents.reversed()) { e in
                            HStack(alignment: .top, spacing: 10) {
                                Text(UFormat.time(e.date))
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

            MBtn(title: "复制日志", kind: .secondary, full: true, height: 48) {
                UIPasteboard.general.string = sync.exportText()
            }
            .padding(.horizontal, MSheetMetrics.contentInset).padding(.vertical, 16)
        }
        .presentationBackground(M.panel)
        .presentationDetents([.medium, .large])
    }
}
