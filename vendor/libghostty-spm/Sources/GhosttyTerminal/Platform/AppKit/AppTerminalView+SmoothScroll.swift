//
//  AppTerminalView+SmoothScroll.swift
//  libghostty-spm
//

#if !canImport(UIKit) && canImport(AppKit)
    import AppKit
    import GhosttyKit

    /// The trackpad's and the Magic Mouse's gestures, told to the settler
    /// that brings a viewport left between rows back to a row
    /// (`TerminalSmoothScrollSettler`, Patches/ghostty/0022). The scroll
    /// itself goes to the surface in `scrollWheel(with:)` as before; the
    /// engine decides whether it moves by the pixel.
    ///
    /// While fingers are down or momentum runs, the settler is held. When
    /// momentum ends the viewport goes on to the row ahead at the speed the
    /// momentum ended at. When the fingers lift while the viewport still
    /// moves it goes on to the row ahead the same way, at once: momentum
    /// that follows takes over where the snap got to, in the same direction.
    /// When they lift from a viewport dragged to a stop it waits
    /// `smoothScrollLiftDelay` for momentum, then goes to the nearer row. A
    /// precise event with no phase at all (a synthesized pixel scroll, a
    /// smooth-scrolling utility) is left to the settler's own idle delay.
    ///
    /// uTerm 本地补丁 #19：抬手时还在走的不再停 0.08 s 再动；「还在走」按最近 50 ms 的速度判，
    /// 不按最后一个事件的位移（120 Hz 的触控板上 150 pt/s 每个事件只有 2–3 px，原来当成停住、往回吸；
    /// 手指停住不动再抬起时最后一个事件是 150 ms 前的，原来当成还在走、往前吸最多一整行）。
    extension AppTerminalView {
        /// AppKit sends the first momentum event right after the gesture's
        /// last one; a lift waits this long for it.
        static let smoothScrollLiftDelay: TimeInterval = 0.08
        /// The speed (points per second, over the settler's
        /// `velocityWindow`) from which the viewport counts as still moving
        /// when the fingers lift. A finger resting on a Magic Mouse that
        /// drifts a point in one event comes to 20 pt/s and does not.
        static let smoothScrollMovingSpeed: Double = 30

        /// Before the event's scroll goes to the surface.
        func smoothScrollWillScroll(_ event: NSEvent) {
            guard event.hasPreciseScrollingDeltas else { return }
            let gesture: NSEvent.Phase = [.mayBegin, .began, .changed, .stationary]
            if !event.phase.isDisjoint(with: gesture) || !event.momentumPhase.isDisjoint(with: [.began, .changed]) {
                core.scrollSettler.hold()
            }
        }

        /// After it went.
        func smoothScrollDidScroll(_ event: NSEvent) {
            guard event.hasPreciseScrollingDeltas else { return }
            let settler = core.scrollSettler
            if !event.momentumPhase.isDisjoint(with: [.ended, .cancelled]) {
                settler.release(followingTravel: true)
            } else if event.phase.contains(.ended) {
                // The next touch on a Magic Mouse, or the next flick on a
                // trackpad, cuts the momentum of the one before while it
                // still moves tens of pixels; a snap to the nearer row then
                // goes back up to half a row and the new gesture forward
                // again, which reads as the text jumping back and forth. A
                // scroll dragged to a stop stays where it was put. A moving
                // one sets off at once rather than pausing for momentum: the
                // momentum that follows holds the settler and carries on the
                // same way from wherever the snap got to.
                let pixelsPerPoint = Double(currentScaleFactor())
                let moving = abs(settler.velocity()) >= Self.smoothScrollMovingSpeed * pixelsPerPoint
                settler.release(after: moving ? 0 : Self.smoothScrollLiftDelay, followingTravel: moving)
            } else if event.phase.contains(.cancelled) {
                // Fingers rested on a moving scroll and lifted.
                settler.release(followingTravel: false)
            }
        }
    }
#endif
