//
//  UITerminalView+SystemScrollDelegate.swift
//  libghostty-spm
//

#if canImport(UIKit)
    #if !targetEnvironment(macCatalyst)
        import GhosttyKit
        import UIKit

        /// The hidden scroll view's delegate. Its own object, holding the
        /// view weakly, so `UITerminalView` declares no public
        /// `UIScrollViewDelegate` methods a host subclass could collide with.
        @MainActor
        final class TerminalScrollDriverDelegate: NSObject, UIScrollViewDelegate {
            weak var view: UITerminalView?

            init(view: UITerminalView) {
                self.view = view
            }

            func scrollViewDidScroll(_ scrollView: UIScrollView) {
                view?.systemScrollDidScroll(scrollView)
            }

            func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
                view?.systemScrollWillBeginDragging(scrollView)
            }

            func scrollViewWillEndDragging(
                _ scrollView: UIScrollView,
                withVelocity velocity: CGPoint,
                targetContentOffset: UnsafeMutablePointer<CGPoint>,
            ) {
                view?.systemScrollWillEndDragging(scrollView, velocity: velocity, targetContentOffset: targetContentOffset)
            }

            func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
                view?.systemScrollDidEndDragging(scrollView, willDecelerate: decelerate)
            }

            func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
                view?.systemScrollDidEndMoving(scrollView)
            }

            func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
                view?.systemScrollDidEndMoving(scrollView)
            }
        }

        /// The scroll view's offset moves the engine's viewport by the
        /// pixel, and its landing place is a whole row.
        extension UITerminalView {
            func systemScrollDidScroll(_ scrollView: UIScrollView) {
                guard scrollView === systemScroll.driver else { return }
                let moved = scrollView.contentOffset.y - systemScroll.lastOffset
                systemScroll.lastOffset = scrollView.contentOffset.y
                guard !systemScroll.isSyncing, let (mapping, position) = systemScrollMapping() else { return }
                let previousDidScroll = systemScroll.lastDidScroll
                systemScroll.lastDidScroll = CACurrentMediaTime()
                // One display rate for as long as the scroll moves.
                // uTerm 本地补丁：上游无条件续 display link；这里只在默认做法（`ScrollWakeupSyncDraw.holdLink`）下续，
                // 其余几种是留着做对照测量的。
                if UTermScrollTrace.scrollWakeupSyncDraw == .holdLink { core.holdDisplayLinkForScroll() }
                if abs(moved) > 0.01 {
                    systemScroll.motionDirection = moved > 0 ? 1 : -1
                }
                // uTerm 本地补丁：速度只给对照用的做法看（见 `SystemScrollState.speed`）。
                let interval = systemScroll.lastDidScroll - previousDidScroll
                systemScroll.speed = interval > 0.001 && interval < 0.1 ? abs(moved) / interval : 0
                let offsetPixels = scrollView.contentOffset.y * mapping.scale
                // uTerm 本地补丁：真手录制的位置 signpost（`UTermScrollTrace.signpostScrollOffset`，没在录时不发）。
                UTermScrollTrace.signpostScrollOffset(px: Double(offsetPixels), decelerating: scrollView.isDecelerating,
                                                      tracking: scrollView.isTracking, view: ObjectIdentifier(self))
                // Out of the scroll view's own range is its rubber band.
                applyOverscroll(mapping.overscroll(offsetPixels: offsetPixels))
                // The engine is read here, not remembered: whatever moved
                // the viewport since — output, a scroll multiplier, the
                // engine stopping at an end — the step brings it to the
                // place the offset stands for.
                let delta = position.pixels(to: mapping.enginePixels(offsetPixels: offsetPixels))
                guard position.isAvailable, abs(delta) > 0.001 else { return }
                // 带编号地滚（上游的引擎补丁 0023），然后原地等带着这一步的那一帧交到图层，和 UIKit 这一拍一起提交（上游同）。
                surface?.smoothScrollTracked(byPixels: delta)
                systemScrollWaitForFrame()
                // uTerm 本地补丁：交给引擎的每一步给回归测试逐帧读（`UTermScrollTrace`，关着时不记）：
                // 松手后的减速 / 回弹 / 对齐记 momentum，手指拖着记 drag，再记引擎此刻的行。
                if UTermScrollTrace.isEnabled {
                    UTermScrollTrace.record(systemScrollInMotion ? "momentum" : "drag", Double(delta))
                    if let row = surface?.smoothScrollPosition()?.row { UTermScrollTrace.record("row", Double(row)) }
                }
            }

            /// uTerm 本地补丁：位置刚交给引擎，原地等带着它的那一帧交到图层（见 `UTermScrollTrace.scrollSameFrameWaitMilliseconds`）。
            /// 等到了：交帧块已经在主队列里，这一轮 run loop 接着跑它，和 UIKit 这一拍一起提交。没等到：这一帧照旧晚一拍上屏；
            /// 连着 `scrollSameFrameWaitMissLimit` 帧没等到（渲染跟不上、同步输出挂起、surface 不可见）就歇一会儿不再等。
            /// 时限从这一轮 run loop 醒来算起（`TerminalMainTurnClock`）：这一轮已经花掉的时间也在预算里。
            private func systemScrollWaitForFrame() {
                let budget = UTermScrollTrace.scrollSameFrameWaitMilliseconds
                guard budget > 0, let surface else { return }
                let start = CACurrentMediaTime()
                guard start >= systemScroll.frameWaitSuspendedUntil else { return }
                let deadline = TerminalMainTurnClock.turnStart + budget / 1000
                while !surface.smoothScrollPresented() {
                    if CACurrentMediaTime() >= deadline {
                        systemScroll.frameWaitMisses += 1
                        if systemScroll.frameWaitMisses >= UTermScrollTrace.scrollSameFrameWaitMissLimit {
                            systemScroll.frameWaitMisses = 0
                            systemScroll.frameWaitSuspendedUntil = CACurrentMediaTime() + UTermScrollTrace.scrollSameFrameWaitBackoff
                        }
                        UTermScrollTrace.record("frame-wait-timeout", (CACurrentMediaTime() - start) * 1000)
                        return
                    }
                    usleep(50)
                }
                systemScroll.frameWaitMisses = 0
                if UTermScrollTrace.isEnabled {
                    UTermScrollTrace.record("frame-wait", (CACurrentMediaTime() - start) * 1000)
                }
            }

            func systemScrollWillBeginDragging(_ scrollView: UIScrollView) {
                guard scrollView === systemScroll.driver else { return }
                TerminalDebugLog.log(.input, "system scroll drag began")
                // The view's own momentum (the two-finger scroll's) may
                // still be running; UIKit has stopped its own deceleration
                // itself.
                if momentumScroll.displayLink != nil {
                    stopMomentumScrolling(settle: .none)
                }
                core.scrollSettler.cancel()
                systemScrollCancelAlign()
                systemScroll.isUIKitMoving = false
                // Dragged on: the lift goes by this drag, not by what a
                // touch stopped.
                systemScroll.caughtDirection = 0
                momentumScroll.panIsActive = true
                momentumScroll.settleToken += 1
                softwareKeyboard.tapCandidateArmed = false
                if !usesInlineTextSelection {
                    dismissTouchSelection(restoringViewport: false)
                }
            }

            /// The landing place becomes a whole row, and UIKit decelerates
            /// to it.
            ///
            /// UIKit takes a lift slower than about 250 pt/s for a stop: no
            /// velocity, and the current offset as the landing place, where
            /// it does not move. Rewritten to the nearest row, UIKit slid
            /// there from rest, at its fastest in the first frame, and half
            /// the time the nearest row was behind the finger: dragged on, the
            /// content went back at the lift. Such a lift keeps its landing
            /// place and leaves the finger's speed to the alignment in
            /// `didEndDragging`, which carries on to the row ahead.
            func systemScrollWillEndDragging(
                _ scrollView: UIScrollView,
                velocity: CGPoint,
                targetContentOffset: UnsafeMutablePointer<CGPoint>,
            ) {
                guard scrollView === systemScroll.driver else { return }
                systemScroll.releaseVelocity = 0
                guard !scrollRestsAnywhere, let (mapping, _) = systemScrollMapping() else { return }
                let current = scrollView.contentOffset.y
                if velocity.y == 0, !systemScrollIsOutOfRange {
                    targetContentOffset.pointee.y = current
                    // The pan is attached to this view, which does not
                    // scroll; positive is the finger going down, toward a
                    // smaller offset.
                    systemScroll.releaseVelocity = -scrollView.panGestureRecognizer.velocity(in: self).y
                    return
                }
                // Rounded in the engine's rows (offset + shift), then back.
                targetContentOffset.pointee.y = mapping.landingOffset(
                    proposed: targetContentOffset.pointee.y,
                    current: current,
                )
            }

            func systemScrollDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
                guard scrollView === systemScroll.driver else { return }
                momentumScroll.panIsActive = false
                let releaseVelocity = systemScroll.releaseVelocity
                systemScroll.releaseVelocity = 0
                if decelerate {
                    systemScroll.isUIKitMoving = true
                    systemScroll.lastDidScroll = CACurrentMediaTime()
                    watchUIKitMotion()
                } else {
                    // No deceleration — hardly moved, or already at the
                    // landing place: the alignment is ours.
                    if !scrollRestsAnywhere {
                        systemScrollAlign(animated: true, velocity: releaseVelocity, lifted: true)
                    }
                    systemScrollResyncSoon()
                }
            }

            /// The fallback for `isUIKitMoving`: every quarter second, a
            /// scroll view that is not decelerating and has not scrolled
            /// since is taken to have finished. `didEndDecelerating`
            /// normally comes first.
            private func watchUIKitMotion() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    guard let self, systemScroll.isUIKitMoving, let driver = systemScroll.driver else { return }
                    if driver.isDecelerating || CACurrentMediaTime() - systemScroll.lastDidScroll < 0.25 {
                        watchUIKitMotion()
                        return
                    }
                    systemScroll.isUIKitMoving = false
                    systemScrollSettled()
                }
            }

            /// UIKit's deceleration, or an animation it ran, has ended.
            func systemScrollDidEndMoving(_ scrollView: UIScrollView) {
                guard scrollView === systemScroll.driver else { return }
                systemScroll.isUIKitMoving = false
                systemScrollSettled()
            }

            /// Every finger is up and none dragged: a tap, or a hold. UIKit
            /// stopped its deceleration the moment the finger came down —
            /// what lets a new drag carry on from a moving scroll — and no
            /// delegate call says it stopped between rows. Align shortly
            /// unless a drag follows.
            func systemScrollTouchEnded() {
                guard systemScroll.driver != nil, !momentumScroll.panIsActive else { return }
                settleScrollSoon()
            }
        }
    #endif
#endif
