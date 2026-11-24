import UDesignKit
import SwiftUI

/// 递归删除进度条。删目录期间挂在文件列表上方（工作区侧栏 / 独立 SFTP 窗口共用）。
///
/// 枚举阶段总数未知 → 不定态条 + 「已找到 N 项」；删除阶段 → 确定态条 + 「M / N」。
/// 右侧 ✕ 请求中止（已删掉的部分不回滚，SFTP 没有事务）。
struct SFTPDeletionBar: View {
    let progress: FileBrowserModel.DeletionProgress
    let onCancel: () -> Void

    private var title: String {
        if progress.isCancelling { return String(localized: "正在取消删除「\(RemoteName.isolated(progress.name))」…") }
        return progress.phase == .counting
            ? String(localized: "正在统计「\(RemoteName.isolated(progress.name))」…")
            : String(localized: "正在删除「\(RemoteName.isolated(progress.name))」")
    }

    private var detail: String {
        switch progress.phase {
        case .counting:
            return String(localized: "已找到 \(UFormat.count(progress.count)) 项")
        case .deleting:
            let total = progress.total ?? progress.count
            return "\(UFormat.count(progress.count)) / \(UFormat.count(total))"
        }
    }

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(UD.text3)
                Text(title)
                    .font(.system(size: 11.5))
                    .foregroundStyle(UD.text2)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                Text(detail)
                    .font(UD.mono(10.5))
                    .foregroundStyle(UD.text3)
                    .lineLimit(1)
                    .layoutPriority(1)
                UDIconButton(systemImage: "xmark", size: 20, action: onCancel)
                    .disabled(progress.isCancelling)
                    .help("取消删除")
                    .accessibilityLabel("取消删除")
            }
            bar
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(UD.panel)
        .overlay(alignment: .bottom) {
            Rectangle().fill(UD.border).frame(height: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityValue(detail)
    }

    /// 统计阶段没有总数可言 → 不定态；删除阶段用确定态填充比例。
    @ViewBuilder
    private var bar: some View {
        if progress.phase == .counting {
            UDIndeterminateBar(height: 4)
        } else {
            UDLinearBar(progress: progress.fraction, height: 4)
        }
    }
}

#Preview("SFTPDeletionBar") {
    VStack(spacing: 0) {
        SFTPDeletionBar(
            progress: .init(name: "node_modules", phase: .counting,
                            count: 1_204, total: nil, isCancelling: false),
            onCancel: {})
        SFTPDeletionBar(
            progress: .init(name: "node_modules", phase: .deleting,
                            count: 3_180, total: 8_532, isCancelling: false),
            onCancel: {})
        SFTPDeletionBar(
            progress: .init(name: "node_modules", phase: .deleting,
                            count: 3_180, total: 8_532, isCancelling: true),
            onCancel: {})
    }
    .frame(width: 320)
    .background(UD.bg)
}
