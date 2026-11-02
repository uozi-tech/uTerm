import SwiftUI
import UDesignKit

enum WorkspacePaneHeaderLayout {
    // 分区方案 v3.2：工作区主内容卡里各栏的头（文件树头 / 预览与终端的标签条 / Agent 头）
    // 同高 40、横向对齐，且都**不画底部分隔线** —— 头与下方内容同在卡面上，靠位置分区。
    // 这个值同时作为 UPaneGroupArea 的 stripHeight 传入。
    nonisolated static let height: CGFloat = 40
}

struct WorkspacePaneHeader: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(height: WorkspacePaneHeaderLayout.height)
    }
}
