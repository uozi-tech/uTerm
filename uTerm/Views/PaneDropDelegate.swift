import SwiftUI
import UniformTypeIdentifiers

/// 窗格的拖放区域。视图被划分为 5 个区：
/// - 中心 50%×50% → 在新标签打开
/// - 上 / 下 25% 横条 → 垂直分屏
/// - 左 / 右 25% 竖条 → 水平分屏
enum PaneDropZone: String, Sendable, Hashable {
    case center, top, bottom, leading, trailing
}

/// 单个 `PaneView` 的 `DropDelegate`。读取 `DropInfo.location`，按 25% 边缘带
/// 分类为 `PaneDropZone`：边缘区调用 `onSplit`，中心区调用 `onOpenInNewTab`。
struct PaneDropDelegate: DropDelegate {
    /// 窗格本地坐标系下的尺寸（origin 在左上角）。
    let bounds: CGRect
    @Binding var hoverZone: PaneDropZone?
    /// 边缘区落点：按方向分屏，新窗格连给定服务器 id。
    let onSplit: @MainActor @Sendable (SplitDirection, UUID) -> Void
    /// 中心区落点：在新标签打开给定服务器。
    let onOpenInNewTab: @MainActor @Sendable (UUID) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.plainText])
    }

    func dropEntered(info: DropInfo) {
        hoverZone = zone(for: info.location)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        hoverZone = zone(for: info.location)
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        hoverZone = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        let landedZone = zone(for: info.location) ?? .center
        hoverZone = nil

        guard let provider = info.itemProviders(for: [.plainText]).first(
            where: { $0.canLoadObject(ofClass: NSString.self) }
        ) else {
            return false
        }
        // The completion closure is `@Sendable` / non-isolated. The callbacks
        // are `@MainActor @Sendable`, so they cross the boundary safely and are
        // invoked after the main-actor hop.
        let onSplit = onSplit
        let onOpenInNewTab = onOpenInNewTab
        _ = provider.loadObject(ofClass: NSString.self) { reading, _ in
            guard let s = reading as? NSString,
                  let serverID = UUID(uuidString: s as String) else { return }
            Task { @MainActor in
                switch landedZone {
                case .leading, .trailing:
                    onSplit(.horizontal, serverID)
                case .top, .bottom:
                    onSplit(.vertical, serverID)
                case .center:
                    onOpenInNewTab(serverID)
                }
            }
        }
        return true
    }

    /// 25% 边缘带分类：靠近某条边 → 该边对应的区，否则中心。
    private func zone(for location: CGPoint) -> PaneDropZone? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let nx = (location.x - bounds.minX) / bounds.width
        let ny = (location.y - bounds.minY) / bounds.height
        let edge: CGFloat = 0.25
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
}

/// 被拖拽悬停时窗格上的视觉提示叠层。与 `PaneDropDelegate.zone(for:)` 的分区一致。
struct PaneDropHighlight: View {
    let zone: PaneDropZone
    var color: Color = .accentColor

    var body: some View {
        GeometryReader { geo in
            let edgeThickness: CGFloat = 4
            switch zone {
            case .center:
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(color, lineWidth: 2)
            case .top:
                VStack(spacing: 0) {
                    Rectangle().fill(color).frame(height: edgeThickness)
                    Color.clear
                }
                .background(
                    Rectangle()
                        .fill(color.opacity(0.10))
                        .frame(height: geo.size.height / 2),
                    alignment: .top
                )
            case .bottom:
                VStack(spacing: 0) {
                    Color.clear
                    Rectangle().fill(color).frame(height: edgeThickness)
                }
                .background(
                    Rectangle()
                        .fill(color.opacity(0.10))
                        .frame(height: geo.size.height / 2),
                    alignment: .bottom
                )
            case .leading:
                HStack(spacing: 0) {
                    Rectangle().fill(color).frame(width: edgeThickness)
                    Color.clear
                }
                .background(
                    Rectangle()
                        .fill(color.opacity(0.10))
                        .frame(width: geo.size.width / 2),
                    alignment: .leading
                )
            case .trailing:
                HStack(spacing: 0) {
                    Color.clear
                    Rectangle().fill(color).frame(width: edgeThickness)
                }
                .background(
                    Rectangle()
                        .fill(color.opacity(0.10))
                        .frame(width: geo.size.width / 2),
                    alignment: .trailing
                )
            }
        }
        .allowsHitTesting(false)
    }
}
