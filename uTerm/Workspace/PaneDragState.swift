import AppKit
import Foundation

/// 拖拽悬停目标：某窗格 + 命中的投放区。
nonisolated struct DragHoverTarget: Equatable, Sendable {
    let paneID: UUID
    let zone: PaneDropZone
}

/// 一次窗格拖拽会话的瞬态状态。不持久化。`TabContentView` 以 `@State`
/// 持有，透传给每个 `PaneView` 与各窗格的 `PaneDropDelegate`。
@MainActor
@Observable
final class PaneDragState {
    /// 正在被拖拽的窗格 id；nil 表示当前无拖拽。
    var draggingPaneID: UUID?
    /// 光标当前悬停的投放目标。
    var hover: DragHoverTarget?
    /// 拖拽幽灵内容快照；nil 表示无拖拽 / 不显示幽灵。
    var paneDragPreview: PaneDragPreview?

    @ObservationIgnored private var endPollTask: Task<Void, Never>?

    /// 拖拽开始时由窗格头部的 `.onDrag` 调用。`.onDrag` 没有结束回调，
    /// 故启动一个鼠标释放轮询，松手即 `end()`。
    func begin(paneID: UUID, preview: PaneDragPreview? = nil) {
        draggingPaneID = paneID
        hover = nil
        paneDragPreview = preview
        endPollTask?.cancel()
        endPollTask = Task { @MainActor [weak self] in
            // 30ms 周期：足够灵敏又不空耗。bit 0 = 鼠标左键。
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(30))
                if Task.isCancelled { return }
                if (NSEvent.pressedMouseButtons & 1) == 0 {
                    self?.end()
                    return
                }
            }
        }
    }

    /// 结束拖拽会话。由鼠标释放轮询调用，也由 `PaneDropDelegate.performDrop`
    /// 兜底调用。幂等。
    func end() {
        draggingPaneID = nil
        hover = nil
        paneDragPreview = nil
        endPollTask?.cancel()
        endPollTask = nil
    }
}

/// 一次拖拽幽灵的内容快照。拖拽开始时捕获，由 `DragGhostWindowBridge`
/// 渲染成跟随光标的浮动窗口卡片。值类型，`nonisolated`。
nonisolated struct PaneDragPreview: Equatable, Sendable {
    /// 窗格头部显示的服务器名。
    let name: String
    /// 窗格尺寸（不含投影留白）。
    let paneSize: CGSize
    /// 抓取点相对窗格左上角的偏移；为 nil 时幽灵居中于光标。
    var grabOffset: CGSize?
}

extension PaneDragPreview: DragGhostPreview {
    nonisolated var ghostSize: CGSize { paneSize }
}

/// 抓取点相对窗格左上角的偏移（`width` 向右、`height` 向下）。macOS 屏幕坐标
/// 自下而上，故窗格顶边是 `frame.maxY`，纵向偏移用 `maxY - mouse.y`。结果按
/// 窗格尺寸钳制到 `[0, w] × [0, h]`。
nonisolated func paneGrabOffset(mouse: CGPoint, in frame: CGRect) -> CGSize {
    let dx = min(max(mouse.x - frame.minX, 0), frame.width)
    let dy = min(max(frame.maxY - mouse.y, 0), frame.height)
    return CGSize(width: dx, height: dy)
}
