//
//  TerminalScrollOffsetMapping.swift
//  libghostty-spm
//

import CoreGraphics

/// How a scroll view's content offset maps onto the engine's viewport
/// position, both in pixels from the top of the scrollback. UIKit's system
/// scrolling (`UITerminalView+SystemScroll`) drives the viewport through
/// this; it is kept apart from the view so the arithmetic can be tested on
/// any platform.
///
/// The two ranges are the same length at rest. While output arrives at the
/// bottom under a finger or a bounce, the engine's range grows and the
/// scroll view's does not (resizing it would fight UIKit's tracking), so
/// the scroll view's bottom stands for the engine's and the engine is
/// `shift` pixels ahead of the offset until the scroll rests.
struct TerminalScrollOffsetMapping: Equatable {
    /// Pixels per point.
    let scale: CGFloat
    let cellHeight: Int
    /// The engine's furthest position: the scrollback's length in pixels.
    let engineMax: Int
    /// The scroll view's furthest offset, in pixels.
    let viewMax: CGFloat
    /// Pixels the engine's position is ahead of the offset.
    let shift: Int

    /// The part of an offset outside the scroll view's range, UIKit's
    /// rubber band: positive past the top (the content follows the finger
    /// down), negative past the bottom.
    func overscroll(offsetPixels: CGFloat) -> CGFloat {
        if offsetPixels < 0 { return -offsetPixels }
        if offsetPixels > viewMax { return viewMax - offsetPixels }
        return 0
    }

    /// Within half a pixel of the bottom is the bottom: UIKit rounds an
    /// offset to a fraction of a point that need not be a whole pixel.
    func isAtBottom(offsetPixels: CGFloat) -> Bool {
        offsetPixels >= viewMax - 0.5
    }

    /// The engine position an offset stands for, in whole pixels.
    func enginePixels(offsetPixels: CGFloat) -> Int {
        if isAtBottom(offsetPixels: offsetPixels) { return engineMax }
        let inView = min(max(0, offsetPixels), viewMax)
        return min(max(0, Int(inView.rounded()) + shift), engineMax)
    }

    /// The nearest whole row to an engine position, not past the bottom.
    func nearestRow(enginePixels position: Int) -> Int {
        let row = Int((Double(position) / Double(cellHeight)).rounded())
        return min(engineMax, row * cellHeight)
    }

    /// The offset, in pixels, that shows an engine position.
    func offsetPixels(enginePixels position: Int) -> CGFloat {
        min(max(0, CGFloat(position - shift)), viewMax)
    }

    /// The landing place UIKit proposes for a fling (in points), moved to
    /// the nearest whole row of the engine — but not to one behind
    /// `current`, the offset (in points) the fling starts from.
    ///
    /// uTerm 本地补丁：UIKit 把松手的速度带进改写过的落点（往前往后挪几十点，减速头一帧的速度和不改时一样），
    /// 可落点要是在起点身后，它一帧就把内容拽回去（合成真触摸实测：身后 10 pt，下一帧就是 −10 pt）。
    /// 所以取整只在甩的方向上取：最近的那一行在起点身后时，取起点前方的第一行。
    func landingOffset(proposed points: CGFloat, current: CGFloat) -> CGFloat {
        let cell = CGFloat(cellHeight)
        let engine = clampedEngine(points)
        let from = clampedEngine(current)
        var aligned = (engine / cell).rounded() * cell
        if engine > from {
            // Half a pixel of slack: an offset UIKit rounded onto a row is that row.
            aligned = max(aligned, ((from - 0.5) / cell).rounded(.up) * cell)
        } else if engine < from {
            aligned = min(aligned, ((from + 0.5) / cell).rounded(.down) * cell)
        }
        aligned = min(max(0, aligned), CGFloat(engineMax))
        return min(max(0, aligned - CGFloat(shift)), viewMax) / scale
    }

    /// An offset in points as an engine position in pixels, within the
    /// engine's range.
    private func clampedEngine(_ points: CGFloat) -> CGFloat {
        min(max(0, points * scale + CGFloat(shift)), CGFloat(engineMax))
    }

    /// The whole row a scroll that stopped between rows is brought to: the
    /// nearer one, or — while it still moves (`travel`, positive toward the
    /// bottom) — the first one the way it goes, so the alignment carries on
    /// instead of turning back. Not past the bottom.
    ///
    /// uTerm 本地补丁：慢慢拖着松手（UIKit 的松手速度是 0，见 `systemScrollWillEndDragging`）时，
    /// 手指其实还在动，对齐到最近的一行一半的时候是往回走。
    func restingRow(enginePixels position: Double, travel: Double) -> Int {
        let cell = Double(cellHeight)
        let row: Double = if travel > 0 {
            ((position - 0.5) / cell).rounded(.up)
        } else if travel < 0 {
            ((position + 0.5) / cell).rounded(.down)
        } else {
            (position / cell).rounded()
        }
        return min(engineMax, max(0, Int(row) * cellHeight))
    }

    /// Whether an offset is out of range by more than UIKit's rounding:
    /// a bounce not done.
    static func isOutOfRange(offset: CGFloat, maxOffset: CGFloat, unit: CGFloat) -> Bool {
        offset < -unit || offset > maxOffset + unit
    }

    /// Whether an offset UIKit rounds to `unit` points lands where the
    /// offset already is: writing it moves nothing and brings no
    /// `scrollViewDidScroll`.
    static func rounds(_ target: CGFloat, onto current: CGFloat, unit: CGFloat) -> Bool {
        abs((target / unit).rounded() * unit - current) < unit / 2
    }
}
