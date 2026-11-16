//
//  AppTerminalView+UTermHost.swift
//  uTerm 本地补丁（不在上游）：Mac 宿主要的几个入口——surface 生灭与网格的回调、放掉 / 重建 surface、单个 surface 的行高调整。
//  和 `Platform/UIKit/UITerminalView+UTermHost.swift` 同名同义。
//

#if !canImport(UIKit) && canImport(AppKit)
    import AppKit

    @MainActor
    public extension AppTerminalView {
        /// surface 建好了（它的终端此刻还是出生时的默认网格，真实尺寸随后由 resize 回调报来）。不经 delegate。
        var uTermOnSurfaceAttached: (() -> Void)? {
            get { core.onSurfaceAttached }
            set { core.onSurfaceAttached = newValue }
        }

        /// surface 拆掉了。不经 delegate。
        var uTermOnSurfaceDetached: (() -> Void)? {
            get { core.onSurfaceDetached }
            set { core.onSurfaceDetached = newValue }
        }

        /// 视图按自己的尺寸算出来的网格（列、行）：surface 刚建好、以及之后每次尺寸变化，主线程上同步报来。不经 delegate。
        func uTermSetGridExpectedHandler(_ handler: ((_ columns: Int, _ rows: Int) -> Void)?) {
            core.onGridMetrics = handler.map { handler in
                { metrics in handler(Int(metrics.columns), Int(metrics.rows)) }
            }
        }

        /// surface 被宿主放掉了没有。
        var uTermIsSurfaceReleased: Bool { uTermSurfaceReleased }

        /// 程序收不收没有绑定接的 ⌘ 组合（返回 false 时这类按键不交给引擎，按下、重复、抬起成对丢）。所有按键路径都经它：
        /// 键盘、输入法收字、宿主的 `sendKey`。nil = 照发。见 `TerminalSurface.sendsCommandChords`；同 iOS 的同名属性。
        var uTermSendsCommandChords: (() -> Bool)? {
            get { core.sendsCommandChords }
            set { core.sendsCommandChords = newValue }
        }

        /// 放掉 surface（连同它的交换链、网格和回滚），视图留在原处。给长时间看不见的标签省内存用。
        /// 之后回窗口、布局都不会自己重建，直到 `uTermRestoreSurface()`。放掉的内容宿主要自己有一份（uTerm 是影子终端）。
        func uTermReleaseSurface() {
            guard !uTermSurfaceReleased else { return }
            uTermSurfaceReleased = true
            core.freeSurface()
        }

        /// 引擎现在会不会出帧（surface 建着、视图在窗口里、宿主没声明不可见、窗口没被遮挡）。false = 画面停着，
        /// 新建的 surface 出生就带着这个状态（被遮挡的 surface 整个跳过绘制，窗格是空白）。测试 / 诊断用。
        var uTermCanRenderFrame: Bool { core.canRenderFrame && surface != nil }

        /// 引擎最近一次报来的滚动条（总行数、视口首行、一屏行数）；没有 surface 或还没报过时 nil。
        var uTermScrollbar: TerminalScrollbar? { core.bridge.scrollbar }

        /// uTerm 本地补丁：这个 surface 自己的格子高调整（物理像素，0 = 跟 app 的配置）。surface 重建、app 的配置
        /// 整份推下来时归 0。见 `TerminalSurfaceCoordinator.setCellHeightAdjustment`。
        var uTermCellHeightAdjustment: Int { core.cellHeightAdjustment }

        /// uTerm 本地补丁：把这个 surface 的格子高调成「自然高度 + `pixels`」。没有 surface 或配置解析失败时返回 false。
        @discardableResult
        func uTermSetCellHeightAdjustment(_ pixels: Int) -> Bool {
            core.setCellHeightAdjustment(pixels)
        }

        /// uTerm 本地补丁：surface 用的屏幕倍率（视图点 × 它 = 引擎的物理像素）。
        var uTermScaleFactor: Double { core.scaleFactor() }

        /// 清掉选区（程序清了屏、擦掉了选中的内容）。`onlyIfBlank`：只在选区里只剩空白时清。输入法正在组字时不动
        /// （清选区的入口会连预编辑一起清掉，见 `TerminalSurface.clearSelectionWithoutInput`）。返回清没清。
        @discardableResult
        func uTermClearSelection(onlyIfBlank: Bool) -> Bool {
            guard let surface else { return false }
            if onlyIfBlank, !surface.selectionIsBlank() { return false }
            return surface.clearSelectionWithoutInput(composing: hasMarkedText())
        }

        /// 重新建 surface（视图在窗口里、有尺寸时当场建好，否则等它回到窗口）。
        func uTermRestoreSurface() {
            guard uTermSurfaceReleased else { return }
            uTermSurfaceReleased = false
            guard window != nil else { return }
            core.fitToSize()
            updateMetalLayerMetrics()
            updateColorScheme()
            reportDisplayID()
        }
    }
    public extension AppTerminalView {
        /// uTerm 测试用：视口此刻的位置（读引擎，`ghostty_surface_smooth_scroll`）和吸附在不在跑。
        struct UTermScrollState: Equatable, Sendable {
            /// 视口首行行号。
            public let row: Int
            /// 首行顶边之上滚出去的像素（引擎记的小数，`[0, 格子高)`）。
            public let fraction: Double
            public let isSnapping: Bool
            /// `fraction` 四舍五入到整像素。
            public var fractionPixels: Int { Int(fraction.rounded()) }
            /// 没有吸附在跑，视口在整行上。
            public var isAtRest: Bool { fraction == 0 && !isSnapping }
        }

        /// 没有 surface、或引擎还没有格子高时：行号取滚动条报的、小数为 0。
        var uTermScrollState: UTermScrollState {
            let position = surface?.smoothScrollPosition()
            return UTermScrollState(row: position?.row ?? uTermScrollbarOffset ?? 0, fraction: position?.fraction ?? 0,
                                    isSnapping: core.scrollSettler.isSnapping)
        }

        /// uTerm 测试用：引擎最近一次报的滚动条行号（视口首行）；还没报过时为 nil。
        var uTermScrollbarOffset: Int? { core.bridge.scrollbar.map { Int($0.offset) } }

        /// uTerm 测试用：Ghostty 报的一个格子的物理像素尺寸；还没有 surface 时为 nil。
        var uTermCellPixels: CGSize? {
            guard let metrics = surface?.size(), metrics.cellWidthPixels > 0, metrics.cellHeightPixels > 0 else { return nil }
            return CGSize(width: Int(metrics.cellWidthPixels), height: Int(metrics.cellHeightPixels))
        }
    }
#endif
