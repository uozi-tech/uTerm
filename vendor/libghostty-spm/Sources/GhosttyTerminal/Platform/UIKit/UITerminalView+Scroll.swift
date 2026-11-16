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

        /// A finger is dragging: from a pan's `.began` to its end, the
        /// scroll view's pan included.
        var panIsActive = false
        /// Invalidates a pending settle when a gesture or momentum follows.
        var settleToken = 0
        // uTerm 本地补丁（抓鼠标的程序松手后的惯性）：这段惯性的位移是不是按行报给程序的（起惯性那一刻定），
        // 以及它慢到多少 pt/s 就停（见 startMomentumScrolling）。
        var reportsToProgram = false
        var stopSpeed: CGFloat = 50
    }

    extension UITerminalView {
        @objc func handleScrollWheelGesture(_ gesture: UIPanGestureRecognizer) {
            guard pointer.session.reported == nil else { return }
            switch gesture.state {
            case .began:
                dismissTouchSelection(restoringViewport: false)
                stopMomentumScrolling(settle: .none)
                core.scrollSettler.hold()
            case .changed:
                core.scrollSettler.hold()
            case .ended:
                // `.ended` still carries whatever moved since the last
                // `.changed`.
                break
            case .cancelled, .failed:
                core.scrollSettler.release(followingTravel: false)
                return
            default:
                return
            }
            defer {
                // Brought to a row once the wheel or the trackpad stops,
                // on iPadOS and Mac Catalyst alike: the pointer hovers and
                // clicks in whole rows. A notch can be under half a row, so
                // a viewport still moving goes on to the row ahead rather
                // than back; one dragged to a stop goes to the nearer row.
                if gesture.state == .ended {
                    let settler = core.scrollSettler
                    settler.release(
                        after: TerminalSmoothScrollSettler.idleDelay,
                        followingTravel: abs(settler.lastTravel) >= Self.scrollMovingDelta,
                    )
                }
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
            if pixels.x == 0, pixels.y == 0 { return }
            surface?.sendMouseScroll(
                x: Double(pixels.x),
                y: Double(pixels.y),
                mods: scrollMods.rawValue,
            )
        }

        /// Pixels in the last scroll from which the viewport counts as still
        /// moving when a wheel or trackpad gesture ends.
        static let scrollMovingDelta: Double = 3

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
                #if targetEnvironment(macCatalyst)
                    // The pointer is somewhere else on a Mac: a program
                    // tracking the mouse gets its wheel reports for the
                    // cell under the finger, not under the pointer.
                    if surface?.isMouseCaptured == true {
                        sendPointerPosition(at: gesture.location(in: self), remember: false)
                    }
                #else
                    softwareKeyboard.tapCandidateArmed = false
                #endif
                if !usesInlineTextSelection {
                    dismissTouchSelection(restoringViewport: false)
                }
                TerminalDebugLog.log(.input, "touch scroll began")
                // A drag that takes over from momentum goes on from where
                // it is. The two-finger scroll counts in rows, so it starts
                // from one.
                stopMomentumScrolling(settle: momentumScroll.scrollsLocally ? .now : .none)
                momentumScroll.panIsActive = true
                momentumScroll.settleToken += 1
                // Nothing settles under the finger (`TerminalSmoothScrollSettler`).
                core.scrollSettler.hold()

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
                core.scrollSettler.hold()
                scrollTouchContent(by: translation, momentum: .none)

            case .ended:
                momentumScroll.panIsActive = false
                guard pointer.session.reported == nil else { return }
                let velocity = gesture.velocity(in: self)
                TerminalDebugLog.log(
                    .input,
                    "touch scroll ended velocity=\(String(format: "%.2f", velocity.x))x\(String(format: "%.2f", velocity.y))",
                )
                #if targetEnvironment(macCatalyst)
                    // A program tracking the mouse reads each report as a
                    // wheel notch; a glide would keep sending them.
                    let glides = surface?.isMouseCaptured != true
                #else
                    // uTerm 本地补丁：程序抓着鼠标（Claude 的全屏界面、tmux / vim 开 mouse）时松手也起惯性，
                    // 按行报给程序（见 startMomentumScrolling）。上游在这里拦掉，手指一离屏就停。
                    let glides = true
                #endif
                if glides {
                    startMomentumScrolling(velocity: velocity)
                }
                // Too slow a lift for momentum: dragged to a stop, to the
                // nearer row. Otherwise the momentum settles when it stops.
                if momentumScroll.displayLink == nil {
                    core.scrollSettler.release(followingTravel: false)
                }

            case .cancelled, .failed:
                TerminalDebugLog.log(.input, "touch scroll cancelled")
                momentumScroll.panIsActive = false
                stopMomentumScrolling(settle: .none)
                // A system gesture took the touch: the viewport may be
                // between rows all the same.
                core.scrollSettler.release(followingTravel: false)

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
            // uTerm 本地补丁：给回归测试逐帧读（`UTermScrollTrace`，关着时不记）。
            if momentum == .none, pixels.y != 0 { UTermScrollTrace.record("drag", Double(pixels.y)) }
            if let bar = core.bridge.scrollbar { UTermScrollTrace.record("row", Double(bar.offset)) }
        }

        /// uTerm 本地补丁：现在的位移是不是按行报给程序（程序抓着鼠标，且不是双指的本地整行滚动）。
        private var scrollReportsToProgram: Bool {
            !(usesInlineTextSelection && momentumScroll.scrollsLocally) && surface?.isMouseCaptured == true
        }

        func startMomentumScrolling(velocity: CGPoint) {
            var velocity = velocity
            var stopSpeed: CGFloat = 50
            // uTerm 本地补丁（抓鼠标的程序松手后的惯性）：位移交给引擎，引擎每攒够一格就给程序报一次滚轮，画面由程序自己
            // 一行一行地重画，和 Mac 触控板的惯性滚动是一回事。和别的惯性（备用屏、没有回滚、双指本地滚动）有三处不同：
            // - 滑得近：距离是 UIScrollView `.normal` 的 `UTermScrollTrace.programMomentumTravel` 倍（四分之一，见 momentumScrollFrame）。
            //   照 `.normal` 滑时 user 觉得太远：整行整行跳的画面跟不住眼睛，程序一次滚轮也可能不止滚一行；
            // - 只留主方向：横向那点速度攒够一格会被报成横向滚轮；
            // - 慢到两行相隔 0.15 s 以上就停：一行一跳的画面，收尾那几下零星的跳比早点停难看
            //  （按 50 pt/s 那条线，13 pt 的行高最后几行要隔 0.26 s 才跳一下）。抬手速度不到这条线的不起惯性。
            let reports = scrollReportsToProgram
            if reports {
                let vertical = abs(velocity.y) >= abs(velocity.x)
                if vertical { velocity.x = 0 } else { velocity.y = 0 }
                if let metrics = surface?.size() {
                    let cell = CGFloat(vertical ? metrics.cellHeightPixels : metrics.cellWidthPixels) / resolvedDisplayScale()
                    stopSpeed = max(stopSpeed, cell / 0.15)
                }
            }
            guard abs(velocity.x) > stopSpeed || abs(velocity.y) > stopSpeed else { return }

            momentumScroll.velocity = velocity
            momentumScroll.reportsToProgram = reports
            momentumScroll.stopSpeed = stopSpeed
            TerminalDebugLog.log(
                .input,
                "momentum start velocity=\(String(format: "%.2f", velocity.x))x\(String(format: "%.2f", velocity.y))",
            )

            scrollTouchContent(by: .zero, momentum: .began)

            let link = CADisplayLink(
                target: self,
                selector: #selector(momentumScrollFrame(_:)),
            )
            // A link with no preferred range runs at 60 Hz on a ProMotion
            // display. The surface draws at 120, so every position was
            // shown for two frames and the glide moved in visible steps.
            link.preferredFrameRateRange = Self.momentumFrameRateRange
            link.add(to: .main, forMode: .common)
            momentumScroll.displayLink = link
        }

        static let momentumFrameRateRange = CAFrameRateRange(
            minimum: 80,
            maximum: 120,
            preferred: 120,
        )

        @objc func momentumScrollFrame(_ link: CADisplayLink) {
            // uTerm 本地补丁：位移的去向途中变了（起的时候程序抓着鼠标，现在它放开了，比如退出了全屏界面；或者反过来），
            // 惯性到此为止。接着走的话，本来报给程序的速度会拿去滚视口，或者本来滚视口的速度变成一串滚轮报给刚起来的程序。
            if momentumScroll.reportsToProgram != scrollReportsToProgram {
                stopMomentumScrolling()
                return
            }
            let dt = link.targetTimestamp - link.timestamp
            // uTerm 本地补丁：减速按 UIScrollView 的 `.normal`（每毫秒 0.998），和系统滚动甩出去的距离、收尾一致。
            // 上游是每 1/60 s 0.92，摩擦大得多，甩一下只滑出去四成。按帧时长缩放，60 / 120 Hz 一样远。
            // 报给程序的那种惯性再按 `programMomentumTravel` 缩短距离（距离和减速率成反比）。
            let travel = momentumScroll.reportsToProgram ? max(0.05, UTermScrollTrace.programMomentumTravel) : 1
            let decay = CGFloat(pow(0.998, dt * 1000 / travel))

            momentumScroll.velocity.x *= decay
            momentumScroll.velocity.y *= decay

            let deltaX = momentumScroll.velocity.x * dt
            let deltaY = momentumScroll.velocity.y * dt

            let stopSpeed = momentumScroll.stopSpeed
            if abs(momentumScroll.velocity.x) < stopSpeed, abs(momentumScroll.velocity.y) < stopSpeed {
                stopMomentumScrolling(settle: .none)
                // Run out: on to the row ahead.
                core.scrollSettler.release(followingTravel: true)
                return
            }

            TerminalDebugLog.log(
                .input,
                "momentum frame velocity=\(String(format: "%.2f", momentumScroll.velocity.x))x\(String(format: "%.2f", momentumScroll.velocity.y)) delta=\(String(format: "%.2f", deltaX))x\(String(format: "%.2f", deltaY))",
            )

            UTermScrollTrace.record("momentum", Double(deltaY * resolvedDisplayScale()))
            scrollTouchContent(by: CGPoint(x: deltaX, y: deltaY), momentum: .changed)
        }

        /// `.now` by default: most callers go on to work in whole rows, or
        /// are taking the view away.
        func stopMomentumScrolling(sendTerminalEndEvent: Bool = true, settle: ScrollSettle = .now) {
            #if !targetEnvironment(macCatalyst)
                if settle != ScrollSettle.none {
                    systemScrollStop()
                }
            #endif
            if momentumScroll.displayLink != nil {
                TerminalDebugLog.log(.input, "momentum stop")

                if sendTerminalEndEvent {
                    scrollTouchContent(by: .zero, momentum: .none)
                }

                momentumScroll.displayLink?.invalidate()
                momentumScroll.displayLink = nil
                momentumScroll.velocity = .zero
            }
            switch settle {
            case .none: break
            case .later: settleScrollSoon()
            case .now: settleScrollNow()
            }
        }
    }
#endif
