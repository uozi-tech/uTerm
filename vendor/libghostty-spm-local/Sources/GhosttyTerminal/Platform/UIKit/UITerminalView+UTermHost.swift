//
//  UITerminalView+UTermHost.swift
//  uTerm 本地补丁（不在上游）：宿主要的几个入口——surface 生灭与网格的回调、放掉 / 重建 surface、按点数设字号。
//

#if canImport(UIKit)
    #if !targetEnvironment(macCatalyst)
        import UIKit

        @MainActor
        public extension UITerminalView {
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

            /// 放掉 surface（连同它的交换链、网格和回滚），视图留在原处。给长时间看不见的标签省内存用：
            /// 每个 surface 约占十几 MB 的帧缓冲，`setSurfaceVisible(false)` 在 iOS 上不还。
            /// 之后布局、回窗口都不会自己重建，直到 `uTermRestoreSurface()`。
            /// 放掉的 surface 里的内容宿主要自己有一份（uTerm 是影子终端），重建后灌回去。
            func uTermReleaseSurface() {
                guard !uTermSurfaceReleased else { return }
                uTermSurfaceReleased = true
                stopMomentumScrolling(sendTerminalEndEvent: false)
                dismissTouchSelection()
                stopKeyRepeat()
                core.freeSurface()
            }

            /// 重新建 surface（视图在窗口里、有尺寸时当场建好，否则等下一次布局）。
            func uTermRestoreSurface() {
                guard uTermSurfaceReleased else { return }
                uTermSurfaceReleased = false
                core.fitToSize()
            }

            /// 把这个 surface 的字号设成 `points`（Ghostty 的点数），并当场按新格子尺寸重算网格。没有 surface 时返回 false。
            /// 和捏合缩放走同一个 binding（`set_font_size`），所以配置重载（切日夜）不会把它改回去。
            @discardableResult
            func uTermSetFontSize(_ points: Float) -> Bool {
                guard let surface, surface.performBindingAction("set_font_size:\(points)") else { return false }
                core.synchronizeMetrics()
                refreshTextInputGeometry(reason: "host-font-size")
                return true
            }
        }
    #endif
#endif
