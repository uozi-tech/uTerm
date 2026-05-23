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

    @ObservationIgnored private var endPollTask: Task<Void, Never>?

    /// 拖拽开始时由窗格头部的 `.onDrag` 调用。`.onDrag` 没有结束回调，
    /// 故启动一个鼠标释放轮询，松手即 `end()`。
    func begin(paneID: UUID) {
        draggingPaneID = paneID
        hover = nil
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
        endPollTask?.cancel()
        endPollTask = nil
    }
}
