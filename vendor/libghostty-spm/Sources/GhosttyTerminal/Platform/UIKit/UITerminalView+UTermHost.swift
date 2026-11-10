//
//  UITerminalView+UTermHost.swift
//  uTerm 本地补丁（不在上游）：宿主要的几个入口——surface 生灭与网格的回调、放掉 / 重建 surface、按点数设字号、
//  问一个硬件按键是不是按键绑定。
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

            /// 这次硬件按键会不会被按键绑定（`keybind` 配置）认下（同 Mac 的 `isKeyBinding(_:)`）。宿主在 legacy 键盘模式下
            /// 丢掉没有绑定的 ⌘ 组合要靠它区分「绑定」和「要编码发给程序的按键」。没有 surface 时 false。
            func uTermIsKeyBinding(_ key: UIKey) -> Bool {
                uTermIsKeyBinding(usage: UInt16(key.keyCode.rawValue), modifierFlags: key.modifierFlags,
                                  charactersIgnoringModifiers: key.charactersIgnoringModifiers)
            }

            /// 同上，按 `UIKey` 的三项拆开给（`UIKey` 造不出来，用例走这一个）。按键事件的拼法与 `handleKeyPress` 里
            /// 按下那一刻的一致（键码、修饰键、consumed、unshifted codepoint；带 ⌘ 时那边也不带文字）。
            func uTermIsKeyBinding(usage: UInt16, modifierFlags: UIKeyModifierFlags,
                                   charactersIgnoringModifiers: String) -> Bool {
                guard let rawSurface = surface?.rawValue else { return false }
                var flags = modifierFlags
                if TerminalInputText.filteredFunctionKeyText(charactersIgnoringModifiers) == nil {
                    flags.remove(.numericPad)
                }
                var keyEvent = ghostty_input_key_s()
                keyEvent.action = GHOSTTY_ACTION_PRESS
                keyEvent.mods = TerminalInputModifiers(from: flags).ghosttyMods
                keyEvent.keycode = TerminalHardwareKeyRouter.appKitKeyCodeForUIKit(usage: usage)
                var consumed = flags
                consumed.remove(.control)
                consumed.remove(.command)
                keyEvent.consumed_mods = TerminalInputModifiers(from: consumed).ghosttyMods
                if let scalar = TerminalInputText.filteredFunctionKeyText(charactersIgnoringModifiers)?.unicodeScalars.first {
                    keyEvent.unshifted_codepoint = scalar.value
                }
                var bindingFlags = ghostty_binding_flags_e(rawValue: 0)
                return ghostty_surface_key_is_binding(rawSurface, keyEvent, &bindingFlags)
            }
        }
    #endif
#endif
