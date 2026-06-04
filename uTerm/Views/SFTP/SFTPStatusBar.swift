import SwiftUI

/// 状态栏（28px）：远程路径（mono）+ 文件夹/文件计数 +（仅传输时）真实进度条。
/// WS 暗色调色板，对齐设计稿 `pages/sftp.jsx` 的 `SftpStatusBar`。
struct SFTPStatusBar: View {
    let path: String
    let entries: [RemoteEntry]
    let selectedCount: Int
    let transfer: FileBrowserModel.TransferState?

    private var folderCount: Int { entries.filter(\.isDirectory).count }
    private var fileCount: Int { entries.count - folderCount }

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Circle().fill(UD.success).frame(width: 6, height: 6)
                Text(path).font(UD.mono(11))
                    .foregroundStyle(UD.text3).lineLimit(1)
            }
            Text("\(folderCount) 个文件夹 · \(fileCount) 个文件"
                + (selectedCount > 0 ? " · 已选择 \(selectedCount) 项" : ""))
                .font(.system(size: 11)).foregroundStyle(UD.text4).lineLimit(1)
            Spacer(minLength: 12)
            if let t = transfer { transferView(t) }
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(UD.panel)
    }

    @ViewBuilder
    private func transferView(_ t: FileBrowserModel.TransferState) -> some View {
        let frac = t.bytesTotal > 0 ? min(1, max(0, Double(t.bytesDone) / Double(t.bytesTotal))) : 0
        HStack(spacing: 9) {
            Image(systemName: t.direction == .up ? "arrow.up" : "arrow.down")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(UD.accent)
            Text("\(t.direction == .up ? "上传" : "下载") \(t.fileName)")
                .font(UD.mono(11)).foregroundStyle(UD.text2).lineLimit(1)
            if t.bytesTotal > 0 {
                ZStack(alignment: .leading) {
                    Capsule().fill(UD.fillMed).frame(width: 110, height: 5)
                    Capsule().fill(UD.accent).frame(width: 110 * frac, height: 5)
                }
                Text("\(Int(frac * 100))%")
                    .font(UD.mono(11)).foregroundStyle(UD.text3)
                    .frame(width: 34, alignment: .trailing)
                Text(SFTPFormat.bytes(t.bytesTotal)).font(UD.mono(11)).foregroundStyle(UD.text4)
            } else {
                ProgressView().controlSize(.small).tint(UD.accent)
            }
        }
    }
}
