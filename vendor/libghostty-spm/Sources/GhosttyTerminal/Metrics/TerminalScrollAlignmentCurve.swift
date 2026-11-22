//
//  TerminalScrollAlignmentCurve.swift
//  libghostty-spm
//
//  uTerm 本地补丁（不在上游）：系统滚动对齐整行那一段动画的曲线。原来是 0.25 s 的三次缓出 `1 - (1-p)^3`，
//  头一帧的速度是全程平均速度的 3 倍：手指停住松手、甩动途中按一下停住，画面都是从静止一下跳到最快再慢下来。
//

import CoreGraphics
import Foundation

/// The alignment of the system scroll to a whole row, as a curve: a cubic
/// that leaves at the speed the scroll had (zero from rest) and arrives at
/// rest, so the speed never jumps where the alignment takes over.
///
/// With `startSlope` (starting speed over average speed) 0 it is
/// smoothstep; with 3, the cubic ease-out `1 - (1-p)^3`. Beyond 3 the cubic
/// would overshoot the row, so a faster start shortens the duration
/// instead.
struct TerminalScrollAlignmentCurve: Equatable {
    var duration: TimeInterval
    var startSlope: CGFloat

    /// The shortest an alignment that keeps a fast start may take.
    static let shortestDuration: TimeInterval = 0.1

    /// `distance` to the row and `velocity` the scroll moves at, in the
    /// same unit (per second); a velocity away from the row counts as rest.
    /// `longest` is the duration from rest.
    init(distance: CGFloat, velocity: CGFloat, longest: TimeInterval) {
        let speed = distance == 0 ? 0 : max(0, velocity * (distance < 0 ? -1 : 1))
        guard speed > 0 else {
            duration = longest
            startSlope = 0
            return
        }
        let span = abs(distance)
        // The duration whose ease-out starts at exactly this speed.
        duration = min(longest, max(Self.shortestDuration, Double(3 * span / speed)))
        startSlope = min(3, speed * CGFloat(duration) / span)
    }

    /// How far along its way the alignment is (0…1) at `progress` (0…1 of
    /// its duration): the cubic Hermite from 0 at `startSlope` to 1 at rest.
    func value(at progress: CGFloat) -> CGFloat {
        let u = min(max(0, progress), 1)
        let u2 = u * u
        let u3 = u2 * u
        return (u3 - 2 * u2 + u) * startSlope + (3 * u2 - 2 * u3)
    }
}
