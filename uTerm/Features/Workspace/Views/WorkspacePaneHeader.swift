import SwiftUI
import UDesignKit

enum WorkspacePaneHeaderLayout {
    // 分区方案 v3.3：工作区主内容卡里各栏的头（文件树头 / 预览标签条 / Agent 头）同高 40、
    // 横向对齐，底部各画一条 1pt `UD.border`（头与正文同为卡面色，线两侧同底），三段连成
    // 一条横线标出正文起点。这个值同时作为 UPaneGroupArea 的 stripHeight 传入。
    // 终端区标签条下面是凹槽，不画这条线。
    nonisolated static let height: CGFloat = 40
}

struct WorkspacePaneHeader: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(height: WorkspacePaneHeaderLayout.height)
            .overlay(alignment: .bottom) { Rectangle().fill(UD.border).frame(height: 1) }
    }
}
