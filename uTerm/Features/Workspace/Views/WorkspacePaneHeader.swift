import SwiftUI
import UDesignKit

enum WorkspacePaneHeaderLayout {
    nonisolated static let contentHeight: CGFloat = 36
    // UPaneGroupArea places its separator below stripHeight, outside the content.
    nonisolated static let separatorHeight: CGFloat = 1
    nonisolated static let totalHeight = contentHeight + separatorHeight
}

struct WorkspacePaneHeader: ViewModifier {
    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            content.frame(height: WorkspacePaneHeaderLayout.contentHeight)
            Rectangle().fill(UD.border)
                .frame(height: WorkspacePaneHeaderLayout.separatorHeight)
        }
    }
}
