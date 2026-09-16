import SwiftUI
import UDesignKit

enum WorkspacePaneHeaderLayout {
    // Full header height with the bottom separator included. This is also the value passed
    // as UPaneGroupArea's stripHeight: since uAppKit 1.4.10 it overlays its separator inside
    // stripHeight, so the side headers do the same to keep all three seams on one baseline.
    nonisolated static let height: CGFloat = 36
    nonisolated static let separatorHeight: CGFloat = 1
}

struct WorkspacePaneHeader: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(height: WorkspacePaneHeaderLayout.height)
            .overlay(alignment: .bottom) {
                Rectangle().fill(UD.border)
                    .frame(height: WorkspacePaneHeaderLayout.separatorHeight)
            }
    }
}
