import AppKit
import SwiftUI
import UAppKitBridge

// MARK: - 为什么不用 `.onTapGesture`

/// 「单击选中、双击打开」（Finder 语义）在 SwiftUI 里如果写成
///
/// ```swift
/// .onTapGesture(count: 2) { open() }
/// .onTapGesture        { select() }
/// ```
///
/// 那么**单击必然是延迟的**：两个 tap 手势互斥，SwiftUI 得先等满系统双击间隔
/// （「按键与鼠标」里的双击速度，默认 ≈0.5s）确认「不会有第二下」才把单击发出去。
/// 实测欢迎页服务器列表点一行要 390~510ms 才高亮 —— 用户报的就是这个。
///
/// 反过来写成 `simultaneousGesture(TapGesture(count: 2))` 也不行：单 / 双击各自
/// 独立计时、互相抢，两次慢单击会被当成双击，真双击又常在 `selectedID` 改动引发
/// 行重渲染时丢掉第二下（`FileBrowserView` 的注释里记着这一版的症状）。
///
/// 出路是**绕开 SwiftUI 的手势消歧**：AppKit 的 `NSEvent` 自带 `clickCount`，
/// 第一下按下时它就是 1，第二下按下时它就是 2 —— 系统已经替我们做完消歧，
/// 且第一下**不需要等**。原生 `NSTableView` 就是这么做的。
///
/// # 为什么是容器级而不是逐行
///
/// `UAppKitBridge` 里的 `.onPointerDown` 是同款思路的旁观探针，但它每挂一次就
/// 多一个 `NSView` + 一个全局 `NSEvent` 监视器。逐行挂 = 每行一个平台视图，
/// 会把工作区侧栏 20000 条目那档的常驻 `NSView` 从 18 个拉回几百个（`.onDrop`
/// 逐行挂那一版的老账，见 `RemoteRowDropTargeting` 的注释）。所以这里跟
/// 「整表一个 `DropDelegate`」同构：**整个列表一个透明层**，落点纵坐标按行高
/// 换算成行号，`RemoteRowDropTargeting` 那套算术原样复用。
///
/// # 保住了什么
///
/// 透明层 `hitTest` 返回 `nil`、监视器原样放行事件（`return event`），所以
/// AppKit / SwiftUI 侧的一切照旧：`.onDrag` 拖拽会话、`.contextMenu` 右键、
/// `.onHover` 悬停高亮、`.accessibilityAction` 无障碍默认动作、`.focusable`
/// 键盘导航都不受影响。行自己的 `.accessibilityAction` 仍是 VoiceOver /
/// 全键盘控制的激活路径 —— 那条路跟鼠标这条路各走各的。

// MARK: - 落点换算

/// 落点 → 行号的算术住在 `UAppKitBridge.UniformRowHit`（本文件原先自带一份）。
/// 挪过去是因为**第三个**同构的层要用它：整表一个 tracking area 的悬停跟踪器
/// （`RowHoverTracker`）。点击层、拖放层（`RemoteRowDropTargeting`）、悬停层
/// 共用同一份算术 —— 行高改一次，三层一起对。

// MARK: - 透明点击层

/// 旁观 `leftMouseDown` 的透明层：自己不画、不吃事件、不参与命中测试。
///
/// 与 `UAppKitBridge.PointerDownProbeView` 同源，两点不同：
/// 1. 回调带上 `clickCount` 与落点纵坐标（那个探针只报「这块被按了」）；
/// 2. 只装一个（挂在行容器上），不是逐行装。
final class RowClickLayerView: NSView {
    /// 左键按下且落在本视图可见范围内。参数是落点在本视图坐标系里的纵坐标
    /// （原点在左上，与 `DropInfo.location` 同源）、本视图高度、以及
    /// `NSEvent.clickCount`。始终在主线程同步回调。
    var onClick: ((CGFloat, CGFloat, Int) -> Void)?

    private var monitor: Any?

    /// 与 SwiftUI / `DropInfo` 同向：y 自顶部向下增长。
    override var isFlipped: Bool { true }

    /// 对命中测试完全透明 —— 下面的内容照常拿到自己的点击、拖拽与右键。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            removeMonitor()
        } else if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                let local = self.convert(event.locationInWindow, from: nil)
                // bounds ∩ visibleRect：滚出视口的那部分不该响应，而 `visibleRect`
                // 单独用又不是「本视图露出来的部分」（在 ScrollView 里它是整个视口，
                // 可能比 bounds 还大）。理由同 `PointerDownHitTest`。
                if self.bounds.intersection(self.visibleRect).contains(local) {
                    self.onClick?(local.y, self.bounds.height, event.clickCount)
                }
                return event   // 原样放行：绝不消费
            }
        }
    }

    /// 视图离开窗口或被拆除时必须调用，否则监视器会随视图一起泄漏。
    func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

private struct RowClickLayer: NSViewRepresentable {
    let select: (CGFloat, CGFloat) -> Void
    let activate: (CGFloat, CGFloat) -> Void

    func makeNSView(context: Context) -> RowClickLayerView {
        let view = RowClickLayerView()
        view.onClick = handler
        return view
    }

    func updateNSView(_ nsView: RowClickLayerView, context: Context) {
        nsView.onClick = handler
    }

    static func dismantleNSView(_ nsView: RowClickLayerView, coordinator: ()) {
        nsView.removeMonitor()
    }

    private var handler: (CGFloat, CGFloat, Int) -> Void {
        { y, height, clickCount in
            // clickCount 1 = 第一下（立刻选中，零等待）；2 = 第二下（打开）。
            // 三连击及以上（clickCount ≥ 3）不再重复触发打开 —— 与 Finder 一致。
            if clickCount == 1 {
                select(y, height)
            } else if clickCount == 2 {
                activate(y, height)
            }
        }
    }
}

extension View {
    /// 给一个等高行容器装上「按下即选中、第二下即打开」的点击层。
    ///
    /// 挂法与整表 `.onDrop(delegate:)` 完全一致 —— **挂在承载行的 `LazyVStack`
    /// 上、`.padding` 之前**，否则落点坐标会带上内边距的偏移。
    ///
    /// - Parameters:
    ///   - select: 第一下按下。参数为落点在容器坐标系里的纵坐标（原点顶部）与容器高度。
    ///   - activate: 第二下按下（双击）。参数同上。
    func clickToSelect(select: @escaping (_ y: CGFloat, _ containerHeight: CGFloat) -> Void,
                       activate: @escaping (_ y: CGFloat, _ containerHeight: CGFloat) -> Void)
        -> some View {
        background(RowClickLayer(select: select, activate: activate))
    }
}
