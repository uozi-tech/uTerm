import SwiftUI

/// 工作区中央上半部的预览/编辑区。Spec 2A 真正动起来 ——
/// 多 tab、可编辑、按 FileKind 分派渲染。
struct PreviewArea: View {
    let model: FilePreviewModel

    var body: some View {
        VStack(spacing: 0) {
            PreviewTabBar(model: model)
            PreviewBodyRouter(model: model)
            PreviewStatusRow(model: model)
        }
        .background(AppTheme.Palette.bgBase)
    }
}
