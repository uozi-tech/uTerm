import UDesignKit
import SwiftUI

/// 状态栏（28px）：远程路径（mono）+ 文件夹/文件计数 + 传输 Dock。
/// WS 暗色调色板，对齐设计稿 `pages/sftp.jsx` 的 `SftpStatusBar`。
struct SFTPStatusBar: View {
    let path: String
    let entries: [RemoteEntry]
    let selectedCount: Int
    let transfers: [FileBrowserModel.TransferItem]
    let onCancel: (UUID) -> Void
    let onCancelAll: () -> Void
    let onClearFinished: () -> Void
    let onRetry: (UUID) -> Void

    private var folderCount: Int { entries.filter(\.isDirectory).count }
    private var fileCount: Int { entries.count - folderCount }

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Circle().fill(UD.success).frame(width: 6, height: 6)
                Text(path).font(UD.mono(11))
                    .foregroundStyle(UD.text3).lineLimit(1).truncationMode(.middle)
                    .help(path)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("已连接")
            .accessibilityValue(path)
            Text("\(UFormat.count(folderCount)) 个文件夹 · \(UFormat.count(fileCount)) 个文件"
                + (selectedCount > 0 ? " · 已选择 \(UFormat.count(selectedCount)) 项" : ""))
                .font(.system(size: 11)).foregroundStyle(UD.text4).lineLimit(1)
            Spacer(minLength: 12)
            SFTPTransfersDock(transfers: transfers,
                              onCancel: onCancel, onCancelAll: onCancelAll,
                              onClearFinished: onClearFinished, onRetry: onRetry)
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: 28)
        .background(UD.panel)
    }
}
