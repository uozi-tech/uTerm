import CoreGraphics
import XCTest
@testable import uTerm

final class RemoteTrackpadGestureTests: XCTestCase {
    private var gesture = RemoteTrackpadGesture()

    override func setUp() {
        super.setUp()
        gesture = RemoteTrackpadGesture()
    }

    private func touch(_ id: Int, _ x: CGFloat, _ y: CGFloat = 100) -> RemoteTrackpadTouch {
        RemoteTrackpadTouch(id: id, location: CGPoint(x: x, y: y))
    }

    // MARK: - 单指

    func test_tap_clicks_left() {
        XCTAssertEqual(gesture.update([touch(1, 100)], at: 0), [])
        XCTAssertEqual(gesture.update([], at: 0.08), [.click(.left)])
    }

    func test_slow_small_movement_moves_pointer_and_never_presses() {
        XCTAssertEqual(gesture.update([touch(1, 100)], at: 0), [])
        XCTAssertEqual(gesture.update([touch(1, 102)], at: 0.2), [], "阈值内不动光标")
        let moved = gesture.update([touch(1, 104)], at: 0.3)
        guard case .movePointer(let delta, _)? = moved.first else { return XCTFail("应开始移动光标: \(moved)") }
        XCTAssertEqual(delta.width, 4, "越过阈值时把攒下的位移一起发，不丢")
        XCTAssertEqual(gesture.tick(at: 1), [], "已判定成移动，时间到了也不会按下左键")
        XCTAssertEqual(gesture.update([], at: 1.1), [], "抬起不算点击")
    }

    func test_pointer_movement_reports_each_step() {
        _ = gesture.update([touch(1, 100)], at: 0)
        _ = gesture.update([touch(1, 110)], at: 0.05)
        let actions = gesture.update([touch(1, 113, 102)], at: 0.1)
        guard case .movePointer(let delta, let speed)? = actions.first else { return XCTFail("\(actions)") }
        XCTAssertEqual(delta, CGSize(width: 3, height: 2))
        XCTAssertGreaterThan(speed, 0)
    }

    func test_holding_still_starts_drag_and_lift_ends_it() {
        _ = gesture.update([touch(1, 100)], at: 0)
        XCTAssertTrue(gesture.needsTick)
        XCTAssertEqual(gesture.tick(at: 0.44), [])
        XCTAssertEqual(gesture.tick(at: 0.45), [.dragBegan])
        XCTAssertFalse(gesture.needsTick)
        let moved = gesture.update([touch(1, 110)], at: 0.5)
        guard case .dragMoved(let delta, _, let location)? = moved.first else { return XCTFail("\(moved)") }
        XCTAssertEqual(delta.width, 10)
        XCTAssertEqual(location.x, 110)
        XCTAssertEqual(gesture.update([], at: 0.6), [.dragEnded])
    }

    func test_tap_whose_lift_arrives_late_still_clicks() {
        // 抬手事件被父视图的手势识别器扣住、晚于按住时长才送到：计时到点时手指其实已经抬起。
        _ = gesture.update([touch(1, 100)], at: 0)
        XCTAssertEqual(gesture.tick(at: 0.5, fingerLifted: true), [], "手指已抬起，不能按下左键")
        XCTAssertTrue(gesture.needsTick)
        XCTAssertEqual(gesture.update([], at: 0.08), [.click(.left)])
        XCTAssertFalse(gesture.needsTick)
    }

    func test_drag_survives_a_second_finger_until_the_first_lifts() {
        _ = gesture.update([touch(1, 100)], at: 0)
        _ = gesture.tick(at: 0.5)
        XCTAssertEqual(gesture.update([touch(1, 100), touch(2, 200)], at: 0.6), [])
        XCTAssertEqual(gesture.update([touch(2, 200)], at: 0.7), [.dragEnded])
        XCTAssertEqual(gesture.update([touch(2, 210)], at: 0.8), [], "第二根手指抬起前不接受新手势")
        XCTAssertEqual(gesture.update([], at: 0.9), [])
    }

    // MARK: - 点击之后

    func test_moving_right_after_a_tap_moves_the_pointer_instead_of_dragging() {
        // 真机日志：点一下、0.04–0.1 s 后接着滑。以前这会按住左键拖拽，把标题栏下的窗口拖走。
        _ = gesture.update([touch(1, 100)], at: 0)
        XCTAssertEqual(gesture.update([], at: 0.05), [.click(.left)])
        _ = gesture.update([touch(2, 100)], at: 0.09)
        guard case .movePointer? = gesture.update([touch(2, 110)], at: 0.12).first else {
            return XCTFail("点完接着滑是移动光标")
        }
        XCTAssertEqual(gesture.update([], at: 0.3), [])
    }

    func test_holding_after_a_tap_drags_only_after_the_normal_hold() {
        _ = gesture.update([touch(1, 100)], at: 0)
        _ = gesture.update([], at: 0.05)
        _ = gesture.update([touch(2, 100)], at: 0.1)
        XCTAssertEqual(gesture.tick(at: 0.1 + RemoteTrackpadGesture.holdDuration - 0.01), [])
        XCTAssertEqual(gesture.tick(at: 0.1 + RemoteTrackpadGesture.holdDuration + 0.01), [.dragBegan])
    }

    func test_quick_tap_right_after_a_swipe_clicks() {
        // 滑到目标上马上点：第一下就要点到。
        _ = gesture.update([touch(1, 100)], at: 0)
        _ = gesture.update([touch(1, 130)], at: 0.05)
        XCTAssertEqual(gesture.update([], at: 0.3), [])
        _ = gesture.update([touch(2, 130)], at: 0.37)
        XCTAssertEqual(gesture.update([], at: 0.42), [.click(.left)])
    }

    func test_two_quick_taps_stay_two_clicks() {
        _ = gesture.update([touch(1, 100)], at: 0)
        XCTAssertEqual(gesture.update([], at: 0.08), [.click(.left)])
        _ = gesture.update([touch(2, 100)], at: 0.2)
        XCTAssertEqual(gesture.update([], at: 0.28), [.click(.left)])
    }

    // MARK: - 双指

    func test_two_finger_tap_clicks_right_even_when_fingers_lift_apart() {
        _ = gesture.update([touch(1, 100), touch(2, 160)], at: 0)
        XCTAssertEqual(gesture.update([touch(2, 160)], at: 0.08), [])
        XCTAssertEqual(gesture.update([], at: 0.12), [.click(.right)])
    }

    func test_second_finger_arriving_late_still_counts_as_two_finger_tap() {
        _ = gesture.update([touch(1, 100)], at: 0)
        _ = gesture.update([touch(1, 100), touch(2, 160)], at: 0.03)
        XCTAssertEqual(gesture.update([], at: 0.1), [.click(.right)])
    }

    func test_long_two_finger_hold_does_not_click() {
        _ = gesture.update([touch(1, 100), touch(2, 160)], at: 0)
        XCTAssertEqual(gesture.update([], at: 0.6), [])
    }

    func test_parallel_fingers_scroll_and_ignore_later_spread_changes() {
        _ = gesture.update([touch(1, 100, 100), touch(2, 160, 100)], at: 0)
        XCTAssertEqual(gesture.update([touch(1, 100, 103), touch(2, 160, 103)], at: 0.02), [], "判定前不发滚动")
        XCTAssertEqual(gesture.update([touch(1, 100, 110), touch(2, 160, 110)], at: 0.05),
                       [.scrollBegan, .scrollMoved(CGSize(width: 0, height: 10))], "判定用掉的位移要补上，内容才跟手")
        XCTAssertEqual(gesture.update([touch(1, 100, 120), touch(2, 160, 120)], at: 0.1),
                       [.scrollMoved(CGSize(width: 0, height: 10))])
        // 滚动很长一段后双指间距变了 50%：锁定在滚动，不会切成缩放。
        let later = gesture.update([touch(1, 85, 130), touch(2, 175, 130)], at: 0.15)
        XCTAssertEqual(later, [.scrollMoved(CGSize(width: 0, height: 10))])
    }

    func test_scroll_end_reports_velocity_only_when_fingers_are_still_moving() {
        _ = gesture.update([touch(1, 100, 100), touch(2, 160, 100)], at: 0)
        _ = gesture.update([touch(1, 100, 110), touch(2, 160, 110)], at: 0.01)
        _ = gesture.update([touch(1, 100, 120), touch(2, 160, 120)], at: 0.02)
        _ = gesture.update([touch(1, 100, 130), touch(2, 160, 130)], at: 0.03)
        guard case .scrollEnded(let velocity)? = gesture.update([], at: 0.04).first else {
            return XCTFail("应结束滚动")
        }
        XCTAssertEqual(velocity.y, 1000, accuracy: 0.001)

        var paused = RemoteTrackpadGesture()
        _ = paused.update([touch(1, 100, 100), touch(2, 160, 100)], at: 0)
        _ = paused.update([touch(1, 100, 110), touch(2, 160, 110)], at: 0.01)
        _ = paused.update([touch(1, 100, 120), touch(2, 160, 120)], at: 0.02)
        XCTAssertEqual(paused.update([], at: 0.5), [.scrollEnded(velocity: .zero)], "停住再抬手不带惯性")
    }

    func test_pinch_never_scrolls_and_zooms_without_a_jump() {
        _ = gesture.update([touch(1, 100), touch(2, 200)], at: 0)
        XCTAssertEqual(gesture.update([touch(1, 95), touch(2, 205)], at: 0.05), [],
                       "判定点本身不缩放：判定用掉的 10% 不会一次补上")
        let actions = gesture.update([touch(1, 95 - 5.5), touch(2, 205 + 5.5)], at: 0.1)
        guard case .zoomed(let factor, let anchor)? = actions.first else { return XCTFail("\(actions)") }
        XCTAssertEqual(factor, 121.0 / 110.0, accuracy: 0.001)
        XCTAssertEqual(anchor.x, 150)
        XCTAssertEqual(actions.count, 1, "中心没动就不平移")
    }

    func test_one_stationary_finger_pinch_is_pinch_not_scroll() {
        _ = gesture.update([touch(1, 100), touch(2, 200)], at: 0)
        XCTAssertEqual(gesture.update([touch(1, 100), touch(2, 210)], at: 0.05), [], "另一根可能只是晚起步，先等等")
        // 沿连线走：两指并排横着滚、后面那根没跟上也是这样，多等到 32pt。
        XCTAssertEqual(gesture.update([touch(1, 100), touch(2, 220)], at: 0.1), [])
        XCTAssertEqual(gesture.update([touch(1, 100), touch(2, 230)], at: 0.15), [])
        XCTAssertEqual(gesture.update([touch(1, 100), touch(2, 235)], at: 0.18), [], "判定点本身不缩放")
        guard case .zoomed? = gesture.update([touch(1, 100), touch(2, 245)], at: 0.2).first else {
            return XCTFail("单指不动的捏合也算捏合")
        }
    }

    /// 支点那根手指被另一根推着往反方向挪了一两个点（捏合时常见）：不算跟着走，仍是捏合。
    func test_anchor_finger_drifting_against_the_mover_stays_pinch() {
        _ = gesture.update([touch(1, 100), touch(2, 200)], at: 0)
        _ = gesture.update([touch(1, 99), touch(2, 220)], at: 0.05)
        XCTAssertEqual(gesture.update([touch(1, 98), touch(2, 235)], at: 0.1), [], "判定点本身不缩放")
        guard case .zoomed? = gesture.update([touch(1, 98), touch(2, 245)], at: 0.15).first else {
            return XCTFail("支点反向微动仍是捏合")
        }
    }

    func test_pinch_with_moving_center_also_pans() {
        _ = gesture.update([touch(1, 100), touch(2, 200)], at: 0)
        _ = gesture.update([touch(1, 95), touch(2, 205)], at: 0.05)
        let actions = gesture.update([touch(1, 105), touch(2, 225)], at: 0.1)
        XCTAssertEqual(actions.last, .panned(CGSize(width: 15, height: 0)))
    }

    // MARK: - 滚动与捏合的区分（真实手指不会同时起步）

    func test_scroll_with_a_late_second_finger_on_a_diagonal_stays_scroll() {
        // 手指呈 45° 摆放，一起往右下滑，第二根晚起步：只看间距变化会误判成捏合。
        _ = gesture.update([touch(1, 100, 100), touch(2, 160, 160)], at: 0)
        XCTAssertEqual(gesture.update([touch(1, 108, 108), touch(2, 160, 160)], at: 0.02), [],
                       "只有一根在动时还不能下结论")
        XCTAssertEqual(gesture.update([touch(1, 112, 112), touch(2, 164, 164)], at: 0.04).first, .scrollBegan,
                       "第二根跟上后方向一致，就是滚动")
    }

    func test_scroll_with_uneven_fingers_along_their_axis_stays_scroll() {
        // 手指左右摆放、横向滚动，前一根比后一根走得多：间距变化和整体位移一样大。
        _ = gesture.update([touch(1, 100), touch(2, 160)], at: 0)
        XCTAssertEqual(gesture.update([touch(1, 104), touch(2, 172)], at: 0.03).first, .scrollBegan)
    }

    func test_pinch_with_opposite_fingers_is_pinch_even_when_the_hand_drifts() {
        _ = gesture.update([touch(1, 100, 100), touch(2, 200, 100)], at: 0)
        XCTAssertEqual(gesture.update([touch(1, 94, 102), touch(2, 206, 102)], at: 0.03), [])
        guard case .zoomed? = gesture.update([touch(1, 90, 103), touch(2, 212, 103)], at: 0.06).first else {
            return XCTFail("反向张开就是捏合")
        }
    }

    func test_one_finger_moving_sideways_with_the_other_still_scrolls() {
        // 手指左右摆放，只有一根在上下走：间距几乎不变，不是捏合。
        _ = gesture.update([touch(1, 100, 100), touch(2, 160, 100)], at: 0)
        XCTAssertEqual(gesture.update([touch(1, 100, 112), touch(2, 160, 100)], at: 0.05), [])
        XCTAssertEqual(gesture.update([touch(1, 100, 118), touch(2, 160, 100)], at: 0.1).first, .scrollBegan)
    }

    // MARK: - 横向双指滚动（两指左右并排，横着走正好沿着两指连线）

    /// 两指同时起步、一起往右走：滚动，横向位移完整发出去。
    func test_side_by_side_fingers_moving_right_together_scroll_horizontally() {
        _ = gesture.update([touch(1, 100), touch(2, 160)], at: 0)
        XCTAssertEqual(gesture.update([touch(1, 108), touch(2, 168)], at: 0.03),
                       [.scrollBegan, .scrollMoved(CGSize(width: 8, height: 0))])
        XCTAssertEqual(gesture.update([touch(1, 118), touch(2, 178)], at: 0.06), [.scrollMoved(CGSize(width: 10, height: 0))])
    }

    func test_side_by_side_fingers_moving_left_together_scroll_horizontally() {
        _ = gesture.update([touch(1, 200), touch(2, 260)], at: 0)
        XCTAssertEqual(gesture.update([touch(1, 192), touch(2, 252)], at: 0.03),
                       [.scrollBegan, .scrollMoved(CGSize(width: -8, height: 0))])
    }

    /// 先后起步：前面那根（往外走，间距变大）先走了一大段，后面那根才跟上。
    func test_side_by_side_late_follower_moving_away_still_scrolls() {
        _ = gesture.update([touch(1, 100), touch(2, 160)], at: 0)
        for (step, x) in [168, 176, 184].enumerated() {
            XCTAssertEqual(gesture.update([touch(1, 100), touch(2, CGFloat(x))], at: 0.02 * Double(step + 1)), [],
                           "后面那根还没起步时不能判成捏合（右指走到 \(x)）")
        }
        let actions = gesture.update([touch(1, 106), touch(2, 190)], at: 0.1)
        XCTAssertEqual(actions.first, .scrollBegan, "跟上之后方向一致，是滚动：\(actions)")
    }

    /// 先后起步：后面那根（往里走，间距变小）先走，前面那根才跟上。
    func test_side_by_side_late_follower_moving_toward_still_scrolls() {
        _ = gesture.update([touch(1, 100), touch(2, 160)], at: 0)
        for (step, x) in [108, 116, 124].enumerated() {
            XCTAssertEqual(gesture.update([touch(1, CGFloat(x)), touch(2, 160)], at: 0.02 * Double(step + 1)), [],
                           "前面那根还没起步时不能判成捏合（左指走到 \(x)）")
        }
        let actions = gesture.update([touch(1, 130), touch(2, 166)], at: 0.1)
        XCTAssertEqual(actions.first, .scrollBegan, "跟上之后方向一致，是滚动：\(actions)")
    }

    /// 后面那根手指被摩擦带着只挪了一两个点（不到「起步」的 3pt），另一根已经走了一大段：仍是滚动。
    func test_side_by_side_sticky_follower_still_scrolls() {
        _ = gesture.update([touch(1, 100), touch(2, 160)], at: 0)
        var actions = gesture.update([touch(1, 102), touch(2, 168)], at: 0.02)
        actions += gesture.update([touch(1, 102.5), touch(2, 178)], at: 0.04)
        actions += gesture.update([touch(1, 102.8), touch(2, 186)], at: 0.06)
        actions += gesture.update([touch(1, 106), touch(2, 194)], at: 0.08)
        XCTAssertEqual(actions.first, .scrollBegan, "\(actions)")
        XCTAssertFalse(actions.contains { if case .zoomed = $0 { return true } else { return false } })
    }

    /// 反向用例：两指沿连线反向走（真正的捏合），同时起步与先后起步都还是捏合。
    func test_side_by_side_fingers_moving_apart_along_their_line_pinch() {
        _ = gesture.update([touch(1, 100), touch(2, 160)], at: 0)
        XCTAssertEqual(gesture.update([touch(1, 96), touch(2, 164)], at: 0.03), [], "判定点本身不缩放")
        guard case .zoomed? = gesture.update([touch(1, 90), touch(2, 170)], at: 0.06).first else {
            return XCTFail("同时起步的反向张开是捏合")
        }

        var late = RemoteTrackpadGesture()
        _ = late.update([touch(1, 100), touch(2, 160)], at: 0)
        _ = late.update([touch(1, 100), touch(2, 172)], at: 0.02)
        XCTAssertEqual(late.update([touch(1, 94), touch(2, 180)], at: 0.04), [], "另一根反向起步：判成捏合，判定点不缩放")
        guard case .zoomed? = late.update([touch(1, 90), touch(2, 186)], at: 0.06).first else {
            return XCTFail("先后起步的反向张开也是捏合")
        }

        var closing = RemoteTrackpadGesture()
        _ = closing.update([touch(1, 100), touch(2, 200)], at: 0)
        _ = closing.update([touch(1, 106), touch(2, 194)], at: 0.03)
        guard case .zoomed? = closing.update([touch(1, 112), touch(2, 188)], at: 0.06).first else {
            return XCTFail("相向合拢是捏合")
        }
    }

    func test_two_fingers_that_moved_do_not_right_click_on_lift() {
        // 捏合刚开始就抬手：手指已经明显动过，不是双指轻点。
        _ = gesture.update([touch(1, 100), touch(2, 200)], at: 0)
        _ = gesture.update([touch(1, 100), touch(2, 210)], at: 0.05)
        XCTAssertEqual(gesture.update([], at: 0.1), [])

        var released = RemoteTrackpadGesture()
        _ = released.update([touch(1, 100), touch(2, 200)], at: 0)
        _ = released.update([touch(1, 100), touch(2, 210)], at: 0.05)
        XCTAssertEqual(released.update([touch(1, 100)], at: 0.08), [])
        XCTAssertEqual(released.update([], at: 0.1), [])
    }

    // MARK: - 惯性与中断

    func test_touch_that_stops_momentum_does_not_click() {
        gesture.suppressNextTap()
        _ = gesture.update([touch(1, 100)], at: 0)
        XCTAssertEqual(gesture.update([], at: 0.05), [])
        _ = gesture.update([touch(2, 100)], at: 1)
        XCTAssertEqual(gesture.update([], at: 1.05), [.click(.left)], "只吞掉那一下")
    }

    func test_touch_that_stops_momentum_can_still_start_a_scroll() {
        gesture.suppressNextTap()
        _ = gesture.update([touch(1, 100, 100), touch(2, 160, 100)], at: 0)
        XCTAssertEqual(gesture.update([touch(1, 100, 110), touch(2, 160, 110)], at: 0.05).first, .scrollBegan)
    }

    func test_cancel_ends_active_gestures_without_clicking() {
        _ = gesture.update([touch(1, 100)], at: 0)
        XCTAssertEqual(gesture.cancel(), [], "待定的单击被系统收走不算点击")

        _ = gesture.update([touch(1, 100)], at: 1)
        _ = gesture.tick(at: 2)
        XCTAssertEqual(gesture.cancel(), [.dragEnded])

        _ = gesture.update([touch(1, 100, 100), touch(2, 160, 100)], at: 3)
        _ = gesture.update([touch(1, 100, 110), touch(2, 160, 110)], at: 3.05)
        XCTAssertEqual(gesture.cancel(), [.scrollEnded(velocity: .zero)])
    }

    func test_three_fingers_do_nothing_until_all_lift() {
        _ = gesture.update([touch(1, 100), touch(2, 150), touch(3, 200)], at: 0)
        XCTAssertEqual(gesture.update([touch(1, 120), touch(2, 170)], at: 0.05), [])
        XCTAssertEqual(gesture.update([touch(1, 120)], at: 0.06), [])
        XCTAssertEqual(gesture.update([], at: 0.07), [])
        _ = gesture.update([touch(4, 100)], at: 1)
        XCTAssertEqual(gesture.update([], at: 1.05), [.click(.left)])
    }

    // MARK: - 三指扫动

    private func three(_ dx: CGFloat, _ dy: CGFloat = 0, ids: [Int] = [1, 2, 3]) -> [RemoteTrackpadTouch] {
        [touch(ids[0], 100 + dx, 300 + dy), touch(ids[1], 150 + dx, 290 + dy), touch(ids[2], 200 + dx, 310 + dy)]
    }

    func test_three_finger_swipe_fires_once_in_the_finger_direction() {
        let cases: [(CGFloat, CGFloat, RemoteSwipeDirection)] = [
            (-60, 5, .left), (60, -5, .right), (4, -60, .up), (-4, 60, .down),
        ]
        for (dx, dy, direction) in cases {
            var gesture = RemoteTrackpadGesture()
            XCTAssertEqual(gesture.update(three(0), at: 0), [])
            XCTAssertEqual(gesture.update(three(dx / 2, dy / 2), at: 0.05), [], "没走够 \(direction)")
            XCTAssertEqual(gesture.update(three(dx, dy), at: 0.1), [.swiped(direction)])
            XCTAssertEqual(gesture.update(three(dx * 3, dy * 3), at: 0.15), [], "一次接触只扫一次")
            XCTAssertEqual(gesture.update(Array(three(dx * 3, dy * 3).prefix(1)), at: 0.2), [])
            XCTAssertEqual(gesture.update([], at: 0.25), [], "抬手不算点击")
            _ = gesture.update([touch(9, 100)], at: 1)
            XCTAssertEqual(gesture.update([], at: 1.05), [.click(.left)], "抬手后照常接受新手势")
        }
    }

    func test_three_fingers_landing_one_by_one_still_swipe() {
        _ = gesture.update([touch(1, 100, 300)], at: 0)
        _ = gesture.update([touch(1, 101, 300), touch(2, 150, 290)], at: 0.02)
        XCTAssertEqual(gesture.update(three(2), at: 0.04), [])
        XCTAssertEqual(gesture.update(three(-50), at: 0.1), [.swiped(.left)])
    }

    func test_third_finger_after_pointer_started_moving_still_swipes() {
        _ = gesture.update([touch(1, 100, 300)], at: 0)
        let moved = gesture.update([touch(1, 106, 300)], at: 0.02)
        guard case .movePointer? = moved.first else { return XCTFail("第一根先动了光标: \(moved)") }
        _ = gesture.update([touch(1, 106, 300), touch(2, 150, 290), touch(3, 200, 310)], at: 0.04)
        let swiped = gesture.update([touch(1, 166, 300), touch(2, 210, 290), touch(3, 260, 310)], at: 0.1)
        XCTAssertEqual(swiped, [.swiped(.right)])
    }

    func test_short_three_finger_touch_does_nothing() {
        _ = gesture.update(three(0), at: 0)
        XCTAssertEqual(gesture.update(three(20, 3), at: 0.05), [])
        XCTAssertEqual(gesture.update([], at: 0.1), [], "三指轻点不点击")
    }

    func test_diagonal_three_finger_swipe_does_nothing() {
        _ = gesture.update(three(0), at: 0)
        XCTAssertEqual(gesture.update(three(50, 45), at: 0.1), [])
        XCTAssertEqual(gesture.update([], at: 0.15), [])
    }

    func test_lifting_a_finger_before_the_swipe_cancels_it() {
        _ = gesture.update(three(0), at: 0)
        _ = gesture.update(Array(three(10).prefix(2)), at: 0.05)
        XCTAssertEqual(gesture.update([touch(1, 40, 300), touch(2, 90, 290)], at: 0.1), [], "剩两指不改判滚动")
        XCTAssertEqual(gesture.update([], at: 0.15), [])
    }

    func test_four_fingers_do_not_swipe() {
        _ = gesture.update(three(0) + [touch(4, 250, 300)], at: 0)
        XCTAssertEqual(gesture.update(three(-80) + [touch(4, 170, 300)], at: 0.1), [])
    }

    func test_swipe_maps_to_mission_control_shortcuts() {
        XCTAssertEqual(RemoteSwipeDirection.left.shortcut.code, RemoteKeyMap.Key.right, "手指往左 = 去右边的桌面")
        XCTAssertEqual(RemoteSwipeDirection.right.shortcut.code, RemoteKeyMap.Key.left)
        XCTAssertEqual(RemoteSwipeDirection.up.shortcut.code, RemoteKeyMap.Key.up)
        XCTAssertEqual(RemoteSwipeDirection.down.shortcut.code, RemoteKeyMap.Key.down)
        for direction in [RemoteSwipeDirection.left, .right, .up, .down] {
            XCTAssertEqual(direction.shortcut.modifiers, .control)
        }
    }
}
