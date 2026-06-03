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
        // 预览区主体即编辑器（EditorTheme.background = VS Code #1F1F1F）；铺同色，
        // tab 条 / 状态行以 UD.panel 叠在其上，编辑器正文无缝。
        .background(Color(nsColor: EditorTheme.background))
    }
}
