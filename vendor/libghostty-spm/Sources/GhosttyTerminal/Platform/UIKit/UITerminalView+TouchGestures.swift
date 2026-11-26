//
//  UITerminalView+TouchGestures.swift
//  libghostty-spm
//

#if canImport(UIKit)
    #if !targetEnvironment(macCatalyst)
        import UIKit

        extension UITerminalView {
            /// Direct-touch grammar: single tap for selection dismissal/keyboard,
            /// double tap for a word, triple tap for a row, long press for a word or the menu.
            ///
            /// uTerm 补丁 #25：轻点抬手就生效。上游让单击等双击判定失败、双击等三击判定失败，每一下轻点（弹键盘、
            /// 报给接管鼠标的程序、开链接）都要等完系统的双击间隔。这里另挂一个不等任何人的单击（`quickTap`），
            /// 抬手就做；它和三个连点识别器同时认。连点的后几下（系统给的 `UITouch.tapCount` > 1）它不管，
            /// 交给双击 / 三击（它们照上游，双击仍等三击判定完：不等的话双击选出词就弹编辑菜单，第三下被菜单吃掉）。
            /// 只剩收键盘一件事还等双击判定完（还是原来那个单击识别器）：双击选词不该先把键盘收走。
            func setupTouchSelectionGestures() {
                let quick = UITapGestureRecognizer(target: self, action: #selector(handleQuickTap(_:)))
                quick.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
                quick.delegate = self
                addGestureRecognizer(quick)
                touchSelection.quickTap = quick
                for count in 1 ... 3 {
                    let tap = UITapGestureRecognizer(target: self, action: #selector(handleSelectionTap(_:)))
                    tap.numberOfTapsRequired = count
                    tap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
                    tap.delegate = self
                    addGestureRecognizer(tap)
                    touchSelection.tapRecognizers.append(tap)
                }
                touchSelection.tapRecognizers[0].require(toFail: touchSelection.tapRecognizers[1])
                touchSelection.tapRecognizers[1].require(toFail: touchSelection.tapRecognizers[2])
                updateTouchSelectionGestures()
            }

            func updateTouchSelectionGestures() {
                touchSelection.quickTap?.isEnabled = usesInlineTextSelection
                for tap in touchSelection.tapRecognizers {
                    tap.isEnabled = usesInlineTextSelection
                }
                touchSelection.scrollGesture?.maximumNumberOfTouches = usesInlineTextSelection ? 2 : 1
            }

            /// 轻点的四个识别器（`quickTap` 与单击、双击、三击）之间同时认：一个认出来不让别的失败。
            func isTouchTapRecognizer(_ gesture: UIGestureRecognizer) -> Bool {
                gesture === touchSelection.quickTap || touchSelection.tapRecognizers.contains { $0 === gesture }
            }

            /// 抬手就到：清选区、收菜单、点击（或开链接）、弹键盘。连点的后几下（按下时记的 `tapCountAtTouchDown`）
            /// 不做，归双击 / 三击。
            @objc func handleQuickTap(_ gesture: UITapGestureRecognizer) {
                guard usesInlineTextSelection, gesture.state == .ended, surface != nil else { return }
                let beganWithMenu = touchSelection.tapBeganWithMenu
                let stopsMomentum = touchSelection.tapStopsMomentum
                touchSelection.tapBeganWithMenu = false
                touchSelection.tapStopsMomentum = false
                touchSelection.keyboardTogglePending = false
                guard touchSelection.tapCountAtTouchDown <= 1 else { return }
                performQuickTap(at: gesture.location(in: self), beganWithMenu: beganWithMenu, stopsMomentum: stopsMomentum)
            }

            private func performQuickTap(at point: CGPoint, beganWithMenu: Bool, stopsMomentum: Bool) {
                // A tap that stopped a moving scroll leaves the viewport
                // where it stopped, to be aligned in a moment, not at once.
                if stopsMomentum {
                    stopMomentumScrolling(settle: .later)
                    return
                }
                stopMomentumScrolling(settle: .none)
                let point = settleScrollNow(keeping: point)
                recordTouchTapCell(at: point)
                if touchSelection.range != nil {
                    dismissTouchSelection()
                } else if beganWithMenu || isTouchMenuVisible {
                    if #available(iOS 16.0, *) {
                        selectionEditMenuInteraction.dismissMenu()
                    } else {
                        UIMenuController.shared.hideMenu()
                    }
                } else if !sendTapClick(at: point) {
                    // Report the click before the keyboard changes the grid,
                    // including while a TUI owns mouse input.
                    if softwareKeyboard.isVisible {
                        // 收键盘等双击判定完，见 `handleSelectionTap`。
                        touchSelection.keyboardTogglePending = true
                    } else {
                        toggleSoftwareKeyboard()
                    }
                }
            }

            /// 记下这一下点在哪一格（绝对格号，不随视口与行数变化）：第一下弹了键盘、网格随之变了行数，第二下认成双击时
            /// 按这一格选，不按变了之后手指底下的那一格。
            private func recordTouchTapCell(at point: CGPoint) {
                guard let surface, let grid = touchSelectionGrid() else {
                    touchSelection.lastTap = nil
                    return
                }
                let offset = surface.smoothScrollPosition().flatMap { $0.isAvailable ? $0.row : nil } ?? touchViewportOffset
                touchSelection.lastTap = TouchTapRecord(
                    cell: grid.cell(at: point, viewportOffset: offset), columns: grid.columns,
                    time: CACurrentMediaTime(),
                )
            }

            /// 双击 / 三击：选词 / 选行。单击这里只剩收键盘（它等双击判定失败才到）。
            @objc func handleSelectionTap(_ gesture: UITapGestureRecognizer) {
                guard usesInlineTextSelection, gesture.state == .ended, surface != nil else { return }
                guard gesture.numberOfTapsRequired > 1 else {
                    if touchSelection.keyboardTogglePending {
                        touchSelection.keyboardTogglePending = false
                        toggleSoftwareKeyboard()
                    }
                    return
                }
                touchSelection.keyboardTogglePending = false
                stopMomentumScrolling(settle: .none)
                let point = settleScrollNow(keeping: gesture.location(in: self))
                var cell: Int?
                if let last = touchSelection.lastTap, CACurrentMediaTime() - last.time < 1,
                   last.columns == touchSelectionGrid()?.columns
                {
                    cell = last.cell
                }
                switch gesture.numberOfTapsRequired {
                case 3:
                    beginTouchSelection(at: point, selectAll: false, selectLine: true, cell: cell)
                default:
                    beginTouchSelection(at: point, selectAll: false, cell: cell)
                }
            }

            /// Once selection is active, a one-finger pan extends around a fixed
            /// endpoint; a two-finger pan remains available for local scrollback.
            func handleTouchSelectionPan(_ gesture: UIPanGestureRecognizer) {
                guard let range = touchSelection.range, let grid = touchSelection.grid else { return }
                let point = gesture.location(in: self)
                switch gesture.state {
                case .began:
                    stopMomentumScrolling()
                    if #available(iOS 16.0, *) {
                        selectionEditMenuInteraction.dismissMenu()
                    }
                    let cell = grid.cell(at: point, viewportOffset: touchViewportOffset)
                    func near(_ endpoint: Int) -> Bool {
                        abs(cell % grid.columns - endpoint % grid.columns) < 3
                            && abs(cell / grid.columns - endpoint / grid.columns) < 2
                    }
                    let fixed: Int = if near(range.lowerBound) {
                        range.upperBound
                    } else if near(range.upperBound) {
                        range.lowerBound
                    } else {
                        touchSelection.pivot?.lowerBound ?? range.lowerBound
                    }
                    touchSelection.pivot = surface?.glyphCells(at: fixed, columns: grid.columns)
                    touchSelection.endpoint = .end
                    beginTouchSelectionLoupe(at: point, from: nil)
                case .changed, .ended:
                    touchSelection.dragPoint = point
                    extendTouchSelection(to: point, endpoint: .end)
                    if gesture.state == .ended {
                        finishTouchSelectionDrag(at: point)
                    } else {
                        moveTouchSelectionLoupe(to: point)
                        startTouchSelectionScrolling()
                    }
                case .cancelled, .failed:
                    dismissTouchSelection()
                default:
                    break
                }
            }
        }
    #endif
#endif
