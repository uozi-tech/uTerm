import UDesignKit
import SwiftUI

/// 一个窗格的 5 个投放区。窗格区域划分为：
/// - 中心 50%×50% → 交换
/// - 上 / 下 25% 横条 → 在目标上方 / 下方分屏
/// - 左 / 右 25% 竖条 → 在目标左侧 / 右侧分屏
nonisolated enum PaneDropZone: String, Sendable, Hashable {
    case center, top, bottom, leading, trailing
}

/// 把窗格本地坐标系下的一个点归类到投放区。中心 50%×50% → `center`；
/// 否则归到最近的边。`bounds` 宽或高为零时返回 nil。
nonisolated func paneDropZone(at location: CGPoint, in bounds: CGRect) -> PaneDropZone? {
    guard bounds.width > 0, bounds.height > 0 else { return nil }
    let nx = (location.x - bounds.minX) / bounds.width
    let ny = (location.y - bounds.minY) / bounds.height
    let edge = 0.25
    if nx >= edge && nx <= 1 - edge && ny >= edge && ny <= 1 - edge {
        return .center
    }
    let distLeading = nx
    let distTrailing = 1 - nx
    let distTop = ny
    let distBottom = 1 - ny
    let minDist = min(distLeading, distTrailing, distTop, distBottom)
    switch minDist {
    case distLeading: return .leading
    case distTrailing: return .trailing
    case distTop: return .top
    default: return .bottom
    }
}

/// 拖拽悬停时叠在目标窗格上的投放区提示。区域划分与 `paneDropZone` 对应。
struct PaneDropHighlight: View {
    let zone: PaneDropZone
    var color: Color = UD.accent

    var body: some View {
        GeometryReader { geo in
            let thickness: CGFloat = 4
            switch zone {
            case .center:
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(color, lineWidth: 2)
            case .top:
                VStack(spacing: 0) {
                    Rectangle().fill(color).frame(height: thickness)
                    Color.clear
                }
                .background(
                    Rectangle().fill(color.opacity(0.10))
                        .frame(height: geo.size.height / 2),
                    alignment: .top)
            case .bottom:
                VStack(spacing: 0) {
                    Color.clear
                    Rectangle().fill(color).frame(height: thickness)
                }
                .background(
                    Rectangle().fill(color.opacity(0.10))
                        .frame(height: geo.size.height / 2),
                    alignment: .bottom)
            case .leading:
                HStack(spacing: 0) {
                    Rectangle().fill(color).frame(width: thickness)
                    Color.clear
                }
                .background(
                    Rectangle().fill(color.opacity(0.10))
                        .frame(width: geo.size.width / 2),
                    alignment: .leading)
            case .trailing:
                HStack(spacing: 0) {
                    Color.clear
                    Rectangle().fill(color).frame(width: thickness)
                }
                .background(
                    Rectangle().fill(color.opacity(0.10))
                        .frame(width: geo.size.width / 2),
                    alignment: .trailing)
            }
        }
        .allowsHitTesting(false)
    }
}
