//
//  AppTerminalView+UTermHost.swift
//  uTerm 本地补丁（不在上游）：Mac 宿主要的几个入口——surface 生灭与网格的回调、放掉 / 重建 surface。
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

        /// 放掉 surface（连同它的交换链、网格和回滚），视图留在原处。给长时间看不见的标签省内存用。
        /// 之后回窗口、布局都不会自己重建，直到 `uTermRestoreSurface()`。放掉的内容宿主要自己有一份（uTerm 是影子终端）。
        func uTermReleaseSurface() {
            guard !uTermSurfaceReleased else { return }
            uTermSurfaceReleased = true
            core.freeSurface()
        }

        /// 重新建 surface（视图在窗口里、有尺寸时当场建好，否则等它回到窗口）。
        func uTermRestoreSurface() {
            guard uTermSurfaceReleased else { return }
            uTermSurfaceReleased = false
            guard window != nil else { return }
            core.fitToSize()
            updateMetalLayerMetrics()
            updateColorScheme()
        }
    }
#endif
