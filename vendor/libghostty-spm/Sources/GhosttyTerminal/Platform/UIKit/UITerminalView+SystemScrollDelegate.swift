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
                guard scrollView === systemScroll.driver, !systemScroll.isSyncing,
                      let (mapping, position) = systemScrollMapping() else { return }
                systemScroll.lastDidScroll = CACurrentMediaTime()
                // uTerm 本地补丁：记下走的方向，给被手指按停之后的那次对齐用（`caughtDirection`）。
                let moved = scrollView.contentOffset.y - systemScroll.lastDidScrollOffset
                if abs(moved) > 0.01 { systemScroll.motionDirection = moved > 0 ? 1 : -1 }
                systemScroll.lastDidScrollOffset = scrollView.contentOffset.y
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
                surface?.smoothScroll(byPixels: delta)
                // uTerm 本地补丁：交给引擎的每一步给回归测试逐帧读（`UTermScrollTrace`，关着时不记）：
                // 松手后的减速 / 回弹 / 对齐记 momentum，手指拖着记 drag，再记引擎此刻的行。
                if UTermScrollTrace.isEnabled {
                    UTermScrollTrace.record(systemScrollInMotion ? "momentum" : "drag", Double(delta))
                    if let row = surface?.smoothScrollPosition()?.row { UTermScrollTrace.record("row", Double(row)) }
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
                // uTerm 本地补丁：接着拖了，按停时的方向不再算数，松手时按这次拖动来。
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
            /// uTerm 本地补丁：UIKit 把慢的松手（合成真触摸实测慢于约 250 pt/s）当成停住：速度给 0、提议的落点就是
            /// 现在的位置，不改的话它不减速。原来照样把落点改到最近的一行，UIKit 就自己从静止动过去：头一帧就是
            /// 全程最快（半行 6 pt，头一帧 60 pt/s 起步），而最近的那一行一半的时候在手指身后——手指往前拖、
            /// 一松手内容往回弹。现在这种松手落点留在原处（UIKit 不动它），记下手指的速度，
            /// 由 `didEndDragging(willDecelerate: false)` 的对齐顺着手指的方向、按它的速度接着走到下一行。
            /// 甩出去的落点只在甩的方向上取整（`landingOffset(proposed:current:)`）。
            func systemScrollWillEndDragging(
                _ scrollView: UIScrollView,
                velocity: CGPoint,
                targetContentOffset: UnsafeMutablePointer<CGPoint>,
            ) {
                guard scrollView === systemScroll.driver, let (mapping, _) = systemScrollMapping() else { return }
                systemScroll.releaseVelocity = 0
                let current = scrollView.contentOffset.y
                if velocity.y == 0, !TerminalScrollOffsetMapping.isOutOfRange(
                    offset: current,
                    maxOffset: max(0, scrollView.contentSize.height - scrollView.bounds.height),
                    unit: contentOffsetUnit,
                ) {
                    targetContentOffset.pointee.y = current
                    systemScroll.releaseVelocity = -scrollView.panGestureRecognizer.velocity(in: scrollView).y
                    return
                }
                // Rounded in the engine's rows (offset + shift), then back.
                targetContentOffset.pointee.y = mapping.landingOffset(proposed: targetContentOffset.pointee.y, current: current)
            }

            func systemScrollDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
                guard scrollView === systemScroll.driver else { return }
                momentumScroll.panIsActive = false
                // uTerm 本地补丁：UIKit 当成停住的那次松手，手指的速度（`systemScrollWillEndDragging` 记的）。
                let releaseVelocity = systemScroll.releaseVelocity
                systemScroll.releaseVelocity = 0
                if decelerate {
                    systemScroll.isUIKitMoving = true
                    systemScroll.lastDidScroll = CACurrentMediaTime()
                    watchUIKitMotion()
                } else {
                    // No deceleration — hardly moved, or already at the
                    // landing place: the alignment is ours.
                    systemScrollAlign(animated: true, velocity: releaseVelocity, lifted: true)
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
