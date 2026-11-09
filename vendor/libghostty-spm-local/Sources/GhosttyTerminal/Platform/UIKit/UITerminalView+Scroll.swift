//
//  UITerminalView+Scroll.swift
//  libghostty-spm
//

#if canImport(UIKit)
    import GhosttyKit
    import UIKit

    /// A pan recognizer fed by wheel and trackpad scroll events alone.
    ///
    /// A scroll event is neither a touch nor a pointer drag: it reaches a
    /// pan recognizer only through `allowedScrollTypesMask`, and the touch
    /// recognizers never see it. Refusing every other event here keeps a
    /// finger on the touch-scroll recognizer and a pointer drag on the
    /// selection one without the view's delegate having to tell them apart.
    final class TerminalScrollWheelGestureRecognizer: UIPanGestureRecognizer {
        override init(target: Any?, action: Selector?) {
            super.init(target: target, action: action)
            allowedScrollTypesMask = [.continuous, .discrete]
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
        }

        override func shouldReceive(_ event: UIEvent) -> Bool {
            event.type == .scroll
        }
    }

    /// Touch-scroll momentum state; behavior lives in +Interaction.
    struct MomentumScrollState {
        var displayLink: CADisplayLink?
        var velocity: CGPoint = .zero
        var scrollsLocally = false
        var localRow: CGFloat = 0
        // uTerm 本地补丁（吸附整行，配合 GhosttyKit 0023 的像素级平滑滚动）：手指 / 惯性喂给 surface 的
        // 精确滚动像素累计在这里，停下时补一段把视口落回整行。Ghostty 与 GhosttyKit 的点击、选区命中都按整数视口算，
        // 停在半行会差一行。C 接口不报小数行，只能在 Swift 侧自己记。
        var pixelResidue: CGFloat = 0
        var snapLink: CADisplayLink?
        var snapRemaining: CGFloat = 0
    }

    extension UITerminalView {
        @objc func handleScrollWheelGesture(_ gesture: UIPanGestureRecognizer) {
            guard pointer.session.reported == nil else { return }
            switch gesture.state {
            case .began:
                dismissTouchSelection(restoringViewport: false)
                stopMomentumScrolling()
            case .changed, .ended:
                // `.ended` still carries whatever moved since the last
                // `.changed`.
                break
            default:
                return
            }

            let translation = gesture.translation(in: self)
            gesture.setTranslation(.zero, in: self)
            TerminalDebugLog.log(
                .input,
                "scroll wheel translation=\(String(format: "%.2f", translation.x))x\(String(format: "%.2f", translation.y))",
            )

            // Ghostty's scroll C API has no key mods. The last mouse_pos
            // carries them, so a wheel event can target the cell under the
            // pointer (tmux, vim). View points: Ghostty applies content_scale
            // to a position, unlike the scroll delta below.
            let point = pointer.lastLocation ?? gesture.location(in: self)
            sendPointerPosition(at: point, remember: pointer.lastLocation == nil)

            // Always precision: UIKit hands a discrete wheel notch to the pan
            // recognizer as a point translation, not a line count, and
            // ghostty's non-precision path reads the value as lines times
            // the scroll multiplier.
            let scrollMods = TerminalScrollModifiers(precision: true)
            let pixels = TerminalScrollDistance.scrollPixels(
                for: translation,
                displayScale: resolvedDisplayScale(),
            )
            surface?.sendMouseScroll(
                x: Double(pixels.x),
                y: Double(pixels.y),
                mods: scrollMods.rawValue,
            )
        }

        @objc func handleTouchScrollGesture(
            _ gesture: UIPanGestureRecognizer,
        ) {
            #if !targetEnvironment(macCatalyst)
                if usesInlineTextSelection {
                    if gesture.state == .began {
                        touchSelection.panUsesSelection = touchSelection.range != nil && gesture.numberOfTouches == 1
                        momentumScroll.scrollsLocally = gesture.numberOfTouches == 2
                        momentumScroll.localRow = CGFloat(touchViewportOffset)
                    }
                    if touchSelection.panUsesSelection {
                        handleTouchSelectionPan(gesture)
                        return
                    }
                }
            #endif
            switch gesture.state {
            case .began:
                guard pointer.session.reported == nil else { return }
                #if !targetEnvironment(macCatalyst)
                    softwareKeyboard.tapCandidateArmed = false
                #endif
                if !usesInlineTextSelection {
                    dismissTouchSelection(restoringViewport: false)
                }
                TerminalDebugLog.log(.input, "touch scroll began")
                stopMomentumScrolling()
                stopScrollSnap()

            case .changed:
                guard pointer.session.reported == nil else { return }
                let translation = gesture.translation(in: self)
                gesture.setTranslation(.zero, in: self)
                TerminalDebugLog.log(
                    .input,
                    "touch scroll changed translation=\(String(format: "%.2f", translation.x))x\(String(format: "%.2f", translation.y))",
                )

                if usesInlineTextSelection, !momentumScroll.scrollsLocally {
                    sendPointerPosition(at: gesture.location(in: self))
                }
                scrollTouchContent(by: translation, momentum: .none)

            case .ended:
                guard pointer.session.reported == nil else { return }
                let velocity = gesture.velocity(in: self)
                TerminalDebugLog.log(
                    .input,
                    "touch scroll ended velocity=\(String(format: "%.2f", velocity.x))x\(String(format: "%.2f", velocity.y))",
                )
                if !usesInlineTextSelection || momentumScroll.scrollsLocally || surface?.isMouseCaptured != true {
                    startMomentumScrolling(velocity: velocity)
                }
                // 没起惯性（抬手时几乎不动）就当场吸附；起了惯性的等惯性停下再吸附。
                if momentumScroll.displayLink == nil, surface?.isMouseCaptured != true { snapScrollToRow() }

            case .cancelled, .failed:
                TerminalDebugLog.log(.input, "touch scroll cancelled")
                stopMomentumScrolling()

            default:
                break
            }
        }

        func scrollTouchContent(by delta: CGPoint, momentum: TerminalScrollModifiers.Momentum) {
            if usesInlineTextSelection, momentumScroll.scrollsLocally {
                guard let metrics = surface?.size(), let bar = core.bridge.scrollbar else { return }
                let cellHeight = CGFloat(metrics.cellHeightPixels) / resolvedDisplayScale()
                guard cellHeight > 0 else { return }
                momentumScroll.localRow = min(
                    max(0, CGFloat(bar.total) - CGFloat(bar.len)),
                    max(0, momentumScroll.localRow - delta.y / cellHeight),
                )
                _ = surface?.scrollToRow(UInt(momentumScroll.localRow.rounded()))
                core.requestImmediateTick()
                return
            }
            let pixels = TerminalScrollDistance.scrollPixels(for: delta, displayScale: resolvedDisplayScale())
            let mods = TerminalScrollModifiers(precision: true, momentum: momentum)
            surface?.sendMouseScroll(x: Double(pixels.x), y: Double(pixels.y), mods: mods.rawValue)
            trackScrollResidue(pixels.y)
        }

        // MARK: uTerm 本地补丁：停下时吸附整行

        /// 视口在回滚两端（顶 / 活动区底部）且还往外推时 Ghostty 不留小数行，累计清零；其余时候按发出去的像素累计。
        func trackScrollResidue(_ pixels: CGFloat) {
            guard pixels != 0 else { return }
            guard let bar = core.bridge.scrollbar, bar.total > bar.len else {
                momentumScroll.pixelResidue = 0
                return
            }
            let atTop = bar.offset == 0 && pixels > 0
            let atBottom = bar.offset + bar.len >= bar.total && pixels < 0
            if atTop || atBottom {
                momentumScroll.pixelResidue = 0
                return
            }
            momentumScroll.pixelResidue += pixels
        }

        /// 把累计的小数行补成整行：离哪边近往哪边走，几帧缓动完成。
        func snapScrollToRow() {
            stopScrollSnap()
            guard !momentumScroll.scrollsLocally,
                  let metrics = surface?.size(), metrics.cellHeightPixels > 0 else { return }
            let cell = CGFloat(metrics.cellHeightPixels)
            var r = momentumScroll.pixelResidue.truncatingRemainder(dividingBy: cell)
            if r < 0 { r += cell }
            let delta = r < cell / 2 ? -r : cell - r
            momentumScroll.pixelResidue = 0
            guard abs(delta) >= 0.5 else { return }
            momentumScroll.snapRemaining = delta
            let link = CADisplayLink(target: self, selector: #selector(scrollSnapFrame(_:)))
            link.add(to: .main, forMode: .common)
            momentumScroll.snapLink = link
        }

        @objc func scrollSnapFrame(_: CADisplayLink) {
            let remaining = momentumScroll.snapRemaining
            // 每帧走剩下的 40%（120 Hz 下约 0.1 s 收敛），最后不到 1 像素一次补齐。
            let step = abs(remaining) < 1 ? remaining : remaining * 0.4
            momentumScroll.snapRemaining -= step
            let mods = TerminalScrollModifiers(precision: true, momentum: .none)
            surface?.sendMouseScroll(x: 0, y: Double(step), mods: mods.rawValue)
            if abs(momentumScroll.snapRemaining) < 0.01 { stopScrollSnap() }
        }

        func stopScrollSnap() {
            momentumScroll.snapLink?.invalidate()
            momentumScroll.snapLink = nil
            momentumScroll.snapRemaining = 0
        }

        func startMomentumScrolling(velocity: CGPoint) {
            guard abs(velocity.x) > 50 || abs(velocity.y) > 50 else { return }

            momentumScroll.velocity = velocity
            TerminalDebugLog.log(
                .input,
                "momentum start velocity=\(String(format: "%.2f", velocity.x))x\(String(format: "%.2f", velocity.y))",
            )

            scrollTouchContent(by: .zero, momentum: .began)

            let link = CADisplayLink(
                target: self,
                selector: #selector(momentumScrollFrame(_:)),
            )
            link.add(to: .main, forMode: .common)
            momentumScroll.displayLink = link
        }

        @objc func momentumScrollFrame(_ link: CADisplayLink) {
            let dt = link.targetTimestamp - link.timestamp
            // 0.92 per 1/60 s, scaled to the frame so a flick travels the
            // same distance at 120 Hz as at 60 Hz.
            let decay = CGFloat(pow(0.92, dt * 60))

            momentumScroll.velocity.x *= decay
            momentumScroll.velocity.y *= decay

            let deltaX = momentumScroll.velocity.x * dt
            let deltaY = momentumScroll.velocity.y * dt

            if abs(momentumScroll.velocity.x) < 50, abs(momentumScroll.velocity.y) < 50 {
                stopMomentumScrolling()
                if surface?.isMouseCaptured != true { snapScrollToRow() }
                return
            }

            TerminalDebugLog.log(
                .input,
                "momentum frame velocity=\(String(format: "%.2f", momentumScroll.velocity.x))x\(String(format: "%.2f", momentumScroll.velocity.y)) delta=\(String(format: "%.2f", deltaX))x\(String(format: "%.2f", deltaY))",
            )

            scrollTouchContent(by: CGPoint(x: deltaX, y: deltaY), momentum: .changed)
        }

        func stopMomentumScrolling(sendTerminalEndEvent: Bool = true) {
            guard momentumScroll.displayLink != nil else { return }
            TerminalDebugLog.log(.input, "momentum stop")

            if sendTerminalEndEvent {
                scrollTouchContent(by: .zero, momentum: .none)
            }

            momentumScroll.displayLink?.invalidate()
            momentumScroll.displayLink = nil
            momentumScroll.velocity = .zero
        }
    }
#endif
