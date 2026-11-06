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
        XCTAssertEqual(gesture.update([touch(1, 100), touch(2, 220)], at: 0.1), [], "判定点本身不缩放")
        guard case .zoomed? = gesture.update([touch(1, 100), touch(2, 230)], at: 0.15).first else {
            return XCTFail("单指不动的捏合也算捏合")
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
}
