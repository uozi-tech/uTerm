import AppKit
import SwiftUI

/// 拖拽幽灵内容快照需要向通用面板桥接层提供的最小信息。
nonisolated protocol DragGhostPreview {
    /// 幽灵内容尺寸（不含投影留白）。
    var ghostSize: CGSize { get }

    /// 抓取点相对内容左上角的偏移（`width` 向右、`height` 向下），拖拽开始时
    /// 捕获。幽灵保持该偏移，使其相对光标的位置与原视图一致；为 `nil` 时退化
    /// 为把幽灵居中于光标。
    var grabOffset: CGSize? { get }
}

/// 通用拖拽幽灵浮动面板桥接层。把一个跟随光标的 SwiftUI 幽灵渲染到独立的
/// 无边框子 `NSPanel`，并由 8ms 轮询 `NSEvent.mouseLocation` 跟随光标。
///
/// AppKit `NSDraggingSession` 的拖拽图像无法可靠控制尺寸，故幽灵改由 SwiftUI
/// 在独立 `NSPanel` 中渲染。
struct DragGhostWindowBridge<Preview: DragGhostPreview, Content: View>: NSViewRepresentable {
    let preview: Preview?
    /// 投影向外留白（四边）。面板在内容四周扩展该留白。
    let shadowPadding: CGFloat
    /// 幽灵内容构造闭包。若内容自身不带留白，调用方应在此处自行
    /// `.padding(shadowPadding)`。
    let content: (Preview) -> Content

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughView()
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.attach(to: nsView)
        context.coordinator.configure(shadowPadding: shadowPadding, content: content)
        context.coordinator.update(preview: preview)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.update(preview: nil)
    }

    final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    @MainActor
    final class Coordinator {
        private weak var view: NSView?
        private var preview: Preview?
        private var panel: NSPanel?
        private var hostingView: NSHostingView<AnyView>?
        private var pollTask: Task<Void, Never>?
        private var shadowPadding: CGFloat = 0
        private var content: ((Preview) -> Content)?

        /// 面板尺寸，在 `ensurePanel` 一次性算定（`preview` 整段拖拽不变）。
        private var panelSize: NSSize = .zero
        /// 上一拍的指针位置。指针未移动时跳过整拍，避免 8ms 空转。
        private var lastScreenPoint: NSPoint?

        /// 拖拽开始时的指针位置。在指针移动超过 `showThreshold` 前幽灵保持隐藏，
        /// 使普通点击（AppKit 仍会经 `.onDrag` 路由）不会在原视图上闪现幽灵。
        private var dragStartPoint: NSPoint?
        private let showThreshold: CGFloat = 6

        func attach(to view: NSView) {
            self.view = view
        }

        func configure(shadowPadding: CGFloat, content: @escaping (Preview) -> Content) {
            self.shadowPadding = shadowPadding
            self.content = content
        }

        func update(preview: Preview?) {
            self.preview = preview
            guard let preview else {
                closePanel()
                return
            }
            ensurePanel(for: preview)
            publishMouseLocation()
            startPolling()
        }

        private func ensurePanel(for preview: Preview) {
            guard panel == nil else { return }
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            if let parentWindow = view?.window {
                panel.level = NSWindow.Level(rawValue: parentWindow.level.rawValue + 1)
                parentWindow.addChildWindow(panel, ordered: .above)
            } else {
                panel.level = .floating
            }
            // `preview` 整段拖拽不变：卡片内容与面板尺寸一次性算定，此后每拍
            // 只移动面板原点（见 `publishMouseLocation`）。
            panelSize = NSSize(
                width: max(preview.ghostSize.width, 1) + shadowPadding * 2,
                height: max(preview.ghostSize.height, 1) + shadowPadding * 2
            )
            let hostingView = NSHostingView(rootView: rootView(for: preview))
            hostingView.wantsLayer = true
            hostingView.layer?.backgroundColor = NSColor.clear.cgColor
            hostingView.frame = NSRect(origin: .zero, size: panelSize)
            panel.contentView = hostingView
            panel.setContentSize(panelSize)
            self.hostingView = hostingView
            self.panel = panel
        }

        private func publishMouseLocation() {
            guard let preview, let panel else { return }
            let screenPoint = NSEvent.mouseLocation
            if dragStartPoint == nil { dragStartPoint = screenPoint }
            // 指针未移动则跳过整拍——幽灵内容与尺寸都不变，无需重排或重绘。
            guard screenPoint != lastScreenPoint else { return }
            lastScreenPoint = screenPoint

            let size = NSSize(
                width: max(preview.ghostSize.width, 1),
                height: max(preview.ghostSize.height, 1)
            )
            // 让指针在幽灵内的相对位置与原视图一致（`grabOffset`），使幽灵起始
            // 与原视图对齐。缺省退化为把幽灵居中于光标。
            let grab = preview.grabOffset
                ?? CGSize(width: size.width / 2, height: size.height / 2)
            // 幽灵内容在面板内向四周内缩 `shadowPadding`；屏幕坐标自下而上。
            let originX = screenPoint.x - grab.width - shadowPadding
            let originY = screenPoint.y + grab.height - panelSize.height + shadowPadding
            panel.setFrameOrigin(NSPoint(x: originX, y: originY))

            if !panel.isVisible, let start = dragStartPoint {
                let moved = hypot(screenPoint.x - start.x, screenPoint.y - start.y)
                if moved >= showThreshold {
                    panel.orderFront(nil)
                }
            }
        }

        private func startPolling() {
            guard pollTask == nil else { return }
            pollTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    self?.publishMouseLocation()
                    try? await Task.sleep(for: .milliseconds(8))
                }
            }
        }

        private func closePanel() {
            pollTask?.cancel()
            pollTask = nil
            if let panel {
                panel.parent?.removeChildWindow(panel)
                panel.orderOut(nil)
            }
            panel = nil
            hostingView = nil
            dragStartPoint = nil
            lastScreenPoint = nil
            panelSize = .zero
        }

        deinit {
            MainActor.assumeIsolated {
                closePanel()
            }
        }

        private func rootView(for preview: Preview) -> AnyView {
            guard let content else { return AnyView(EmptyView()) }
            return AnyView(content(preview))
        }
    }
}
