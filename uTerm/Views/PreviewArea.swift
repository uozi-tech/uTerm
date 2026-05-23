import SwiftUI

/// 工作区中央上半部的预览/编辑区。
/// Spec 1 只占位 —— 真正的多 tab 文件渲染留给 Spec 2。
struct PreviewArea: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(AppTheme.Palette.textMuted)
            Text("从左侧选择文件预览")
                .font(.callout)
                .foregroundStyle(AppTheme.Palette.textSecondary)
            Text("Spec 2 落地后这里会显示多 tab 的代码 / Markdown / 图片")
                .font(.caption)
                .foregroundStyle(AppTheme.Palette.textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.Palette.bgBase)
    }
}
