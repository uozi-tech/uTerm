//
//  UITerminalView+SystemScrollAlign.swift
//  libghostty-spm
//

#if canImport(UIKit)
    #if !targetEnvironment(macCatalyst)
        import GhosttyKit
        import UIKit

        /// Stopping the scroll view, and bringing it to a whole row with the
        /// view's own display-link animation (see `SystemScrollState.alignLink`).
        extension UITerminalView {
            static let systemScrollAlignDuration: TimeInterval = 0.25
            static let systemScrollAlignFrameRateRange = CAFrameRateRange(
                minimum: 80,
                maximum: 120,
                preferred: 120,
            )

            /// Stops a deceleration, a bounce or an alignment where it is.
            /// Returns whether there was one.
            @discardableResult
            func systemScrollStop() -> Bool {
                guard let driver = systemScroll.driver, systemScrollInMotion else { return false }
                systemScrollCancelAlign()
                if driver.isDecelerating || systemScroll.isUIKitMoving {
                    // Setting the offset, unanimated, ends UIKit's deceleration.
                    driver.setContentOffset(driver.contentOffset, animated: false)
                }
                systemScroll.isUIKitMoving = false
                return true
            }

            /// Stops the alignment at the frame it has reached.
            func systemScrollCancelAlign() {
                systemScroll.alignLink?.invalidate()
                systemScroll.alignLink = nil
            }

            /// uTerm 本地补丁：比这慢的松手速度（点 / 秒）当成停住，对齐取最近的一行；快一点就取前方的一行。
            static let systemScrollAlignMinimumVelocity: CGFloat = 20

            /// Brings the content offset to the nearest whole row; the engine
            /// follows through `scrollViewDidScroll`. Nothing to do on a row.
            ///
            /// uTerm 本地补丁：`velocity`（点 / 秒，正 = 内容偏移变大）是松手那一刻手指还在动的速度：
            /// 有的话对齐到前方的一行、动画按这个速度起步（`TerminalScrollAlignmentCurve`），从静止起的对齐也从 0 加速，
            /// 不再是三次缓出一上来就是平均速度的 3 倍。
            /// `lifted`：由 `didEndDragging` 调，手指已经抬起，可 UIKit 这时 `isDragging` 还是 true（真触摸实测），
            /// 不看它；原来这一处的对齐因此从没跑过，拖着停住松手要靠改写的落点让 UIKit 自己动过去。
            func systemScrollAlign(animated: Bool, velocity: CGFloat = 0, lifted: Bool = false) {
                guard let driver = systemScroll.driver, let (mapping, position) = systemScrollMapping(),
                      position.isAvailable else { return }
                // A finger is down: the pan writes the offset, and a lift
                // aligns again.
                guard lifted || (!driver.isTracking && !driver.isDragging), !momentumScroll.panIsActive else { return }
                let travel = abs(velocity) < Self.systemScrollAlignMinimumVelocity ? 0 : velocity
                let aligned = mapping.restingRow(enginePixels: position.pixels, travel: Double(travel))
                let targetPixels = mapping.offsetPixels(enginePixels: aligned)
                let offsetPixels = driver.contentOffset.y * mapping.scale
                guard Double(aligned) != position.pixels || abs(offsetPixels - targetPixels) > 0.5 else { return }
                // An offset UIKit rounds to where it already is moves nothing
                // and brings no `scrollViewDidScroll`: align the engine alone.
                // The scroll view is then under half a pixel out.
                let targetPoints = targetPixels / mapping.scale
                if TerminalScrollOffsetMapping.rounds(targetPoints, onto: driver.contentOffset.y, unit: contentOffsetUnit) {
                    surface?.smoothScroll(byPixels: position.pixels(to: aligned))
                    return
                }
                systemScrollCancelAlign()
                guard animated else {
                    driver.contentOffset = CGPoint(x: 0, y: targetPoints)
                    return
                }
                systemScroll.alignFrom = driver.contentOffset.y
                systemScroll.alignTo = targetPoints
                systemScroll.alignStart = 0
                systemScroll.alignCurve = TerminalScrollAlignmentCurve(
                    distance: targetPoints - driver.contentOffset.y,
                    velocity: travel,
                    longest: Self.systemScrollAlignDuration,
                )
                let link = CADisplayLink(target: self, selector: #selector(systemScrollAlignFrame(_:)))
                link.preferredFrameRateRange = Self.systemScrollAlignFrameRateRange
                link.add(to: .main, forMode: .common)
                systemScroll.alignLink = link
            }

            /// One frame of the alignment along its curve; `scrollViewDidScroll`
            /// sends each step to the engine like any other.
            @objc func systemScrollAlignFrame(_ link: CADisplayLink) {
                guard let driver = systemScroll.driver, systemScroll.alignLink === link else {
                    link.invalidate()
                    return
                }
                if systemScroll.alignStart == 0 {
                    systemScroll.alignStart = link.timestamp
                }
                let curve = systemScroll.alignCurve
                let progress = min(1, CGFloat((link.targetTimestamp - systemScroll.alignStart) / curve.duration))
                let eased = curve.value(at: progress)
                driver.contentOffset = CGPoint(
                    x: 0,
                    y: systemScroll.alignFrom + (systemScroll.alignTo - systemScroll.alignFrom) * eased,
                )
                if progress >= 1 {
                    systemScrollCancelAlign()
                    systemScrollSettled()
                }
            }
        }
    #endif
#endif
