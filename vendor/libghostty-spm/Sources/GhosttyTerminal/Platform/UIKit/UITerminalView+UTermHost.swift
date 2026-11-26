//
//  UITerminalView+UTermHost.swift
//  uTerm 本地补丁（不在上游）：宿主要的几个入口——surface 生灭与网格的回调、放掉 / 重建 surface、按点数设字号、
//  没有绑定接的 ⌘ 组合发不发、单个 surface 的行高调整。
//

#if canImport(UIKit)
    #if !targetEnvironment(macCatalyst)
        import GhosttyKit
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

            /// surface 一直保持聚焦：光标不因为视图不是第一响应者就画成空心框，也不由引擎给开了 DEC 1004 的程序报
            /// focus in / out（视图放弃第一响应者、拆 surface 都不报）。宿主要照自己的规则报 1004；程序开 1004 时引擎
            /// 仍会当场报一次「聚焦」（`CSI I`）。见 `TerminalSurfaceCoordinator.keepsSurfaceFocused`。
            var uTermKeepsSurfaceFocused: Bool {
                get { core.keepsSurfaceFocused }
                set { core.keepsSurfaceFocused = newValue }
            }

            /// 一次手指轻点（同轻点手势，测试用）。返回 true = 点到了链接并打开 / 带着 ⌘，不弹键盘。
            func uTermSendTap(at point: CGPoint) -> Bool { sendTapClick(at: point) }

            /// 触摸选区（双击 / 三击 / 长按选出来的、本包自己画高亮的那块）里的文字；没有选区时 nil。测试用。
            var uTermTouchSelectionText: String? { touchSelection.range == nil ? nil : touchSelection.text }

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

            /// 清掉选区（程序清了屏、擦掉了选中的内容）：触摸选区（本包自己画的高亮）和 Ghostty 自己的选区（指针拖出来的）
            /// 都算。`onlyIfBlank`：Ghostty 的选区只在里面只剩空白时清；触摸选区照它自己的规则当场复核一次（选中的
            /// 文字变了就收起）。输入法正在组字时 Ghostty 的选区不动（清它的入口会连预编辑一起清掉）。
            func uTermClearSelection(onlyIfBlank: Bool) {
                if touchSelection.range != nil {
                    if onlyIfBlank {
                        touchSelection.lastValidation = 0
                        refreshTouchSelection()
                    } else {
                        dismissTouchSelection(restoringViewport: false)
                    }
                }
                guard let surface else { return }
                if onlyIfBlank, !surface.selectionIsBlank() { return }
                surface.clearSelectionWithoutInput(composing: inputHandler.hasMarkedText)
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

            /// 程序收不收没有绑定接的 ⌘ 组合（返回 false 时这类按键不交给引擎，按下、重复、抬起成对丢）。所有按键路径都经它：
            /// 硬件键盘、宿主的 `sendKey`。nil = 照发。见 `TerminalSurface.sendsCommandChords`；同 Mac 的同名属性。
            var uTermSendsCommandChords: (() -> Bool)? {
                get { core.sendsCommandChords }
                set { core.sendsCommandChords = newValue }
            }
        }
    #endif
#endif
