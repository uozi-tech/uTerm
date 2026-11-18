import CoreGraphics
import XCTest
@testable import uTerm

/// 触摸屏模式（`RemoteTrackpadGesture.Mode.touch`）：点哪里就是哪里，每个动作前先把指针放到手指的位置。
final class RemoteTouchGestureTests: XCTestCase {
    private var gesture = RemoteTrackpadGesture()

    override func setUp() {
        super.setUp()
        gesture = RemoteTrackpadGesture()
        gesture.mode = .touch
    }

    private func touch(_ id: Int, _ x: CGFloat, _ y: CGFloat = 100) -> RemoteTrackpadTouch {
        RemoteTrackpadTouch(id: id, location: CGPoint(x: x, y: y))
    }

    func test_tap_clicks_where_the_finger_landed() {
        XCTAssertEqual(gesture.update([touch(1, 120, 80)], at: 0), [])
        XCTAssertEqual(gesture.update([], at: 0.08), [.pointerJumped(to: CGPoint(x: 120, y: 80)), .click(.left)])
    }

    func test_finger_wobble_within_slop_is_still_a_tap() {
        _ = gesture.update([touch(1, 100)], at: 0)
        XCTAssertEqual(gesture.update([touch(1, 108)], at: 0.05), [], "直接点目标时手指会滑几个点，不能当成滚动")
        XCTAssertEqual(gesture.update([], at: 0.1), [.pointerJumped(to: CGPoint(x: 100, y: 100)), .click(.left)],
                       "点在落指的位置，不是抬起的位置")
    }

    func test_one_finger_drag_scrolls_under_the_finger() {
        _ = gesture.update([touch(1, 100, 300)], at: 0)
        let began = gesture.update([touch(1, 100, 280)], at: 0.05)
        XCTAssertEqual(began, [.pointerJumped(to: CGPoint(x: 100, y: 300)), .scrollBegan,
                               .scrollMoved(CGSize(width: 0, height: -20))],
                       "指针先放到落指处，判定用掉的位移一起发")
        XCTAssertEqual(gesture.update([touch(1, 100, 270)], at: 0.07), [.scrollMoved(CGSize(width: 0, height: -10))])
        XCTAssertEqual(gesture.tick(at: 1), [], "已判定成滚动，时间到了也不会按下左键")
        let ended = gesture.update([], at: 0.08)
        guard case .scrollEnded(let velocity)? = ended.first, ended.count == 1 else { return XCTFail("\(ended)") }
        XCTAssertLessThan(velocity.y, 0, "带着速度抬手，画布据此续惯性")
    }

    func test_second_finger_during_one_finger_scroll_ends_it() {
        _ = gesture.update([touch(1, 100, 300)], at: 0)
        _ = gesture.update([touch(1, 100, 280)], at: 0.05)
        let ended = gesture.update([touch(1, 100, 280), touch(2, 200, 280)], at: 0.06)
        guard case .scrollEnded? = ended.first, ended.count == 1 else { return XCTFail("\(ended)") }
        XCTAssertEqual(gesture.update([touch(2, 200, 200)], at: 0.2), [], "全部抬起之前不再有动作")
        XCTAssertEqual(gesture.update([], at: 0.3), [])
        _ = gesture.update([touch(3, 50)], at: 1)
        XCTAssertEqual(gesture.update([], at: 1.05), [.pointerJumped(to: CGPoint(x: 50, y: 100)), .click(.left)])
    }

    func test_holding_still_presses_at_the_finger_and_drag_follows_it_exactly() {
        _ = gesture.update([touch(1, 100)], at: 0)
        XCTAssertEqual(gesture.tick(at: 0.44), [])
        XCTAssertEqual(gesture.tick(at: 0.45), [.pointerJumped(to: CGPoint(x: 100, y: 100)), .dragBegan])
        XCTAssertEqual(gesture.update([touch(1, 140, 120)], at: 0.5), [.pointerJumped(to: CGPoint(x: 140, y: 120))],
                       "拖着的东西就在手指下面，不经指针加速")
        XCTAssertEqual(gesture.update([], at: 0.6), [.dragEnded])
    }

    func test_two_finger_tap_right_clicks_between_the_fingers() {
        _ = gesture.update([touch(1, 100), touch(2, 140)], at: 0)
        XCTAssertEqual(gesture.update([], at: 0.1), [.pointerJumped(to: CGPoint(x: 120, y: 100)), .click(.right)])
    }

    func test_two_finger_tap_lifting_one_at_a_time_right_clicks_at_the_same_place() {
        _ = gesture.update([touch(1, 100), touch(2, 140)], at: 0)
        XCTAssertEqual(gesture.update([touch(2, 140)], at: 0.08), [])
        XCTAssertEqual(gesture.update([], at: 0.1), [.pointerJumped(to: CGPoint(x: 120, y: 100)), .click(.right)])
    }

    func test_two_finger_drag_scrolls_under_the_fingers() {
        _ = gesture.update([touch(1, 100, 300), touch(2, 140, 300)], at: 0)
        let began = gesture.update([touch(1, 100, 280), touch(2, 140, 280)], at: 0.05)
        XCTAssertEqual(began, [.pointerJumped(to: CGPoint(x: 120, y: 300)), .scrollBegan,
                               .scrollMoved(CGSize(width: 0, height: -20))])
    }

    func test_cancel_ends_one_finger_scroll_without_momentum() {
        _ = gesture.update([touch(1, 100, 300)], at: 0)
        _ = gesture.update([touch(1, 100, 280)], at: 0.05)
        XCTAssertEqual(gesture.cancel(), [.scrollEnded(velocity: .zero)])
    }

    func test_tap_that_stops_momentum_does_not_click() {
        gesture.suppressNextTap()
        _ = gesture.update([touch(1, 100)], at: 0)
        XCTAssertEqual(gesture.update([], at: 0.05), [])
    }

    func test_trackpad_mode_never_jumps_the_pointer() {
        gesture.mode = .trackpad
        _ = gesture.update([touch(1, 100)], at: 0)
        XCTAssertEqual(gesture.update([], at: 0.08), [.click(.left)])
        _ = gesture.update([touch(1, 100), touch(2, 140)], at: 1)
        XCTAssertEqual(gesture.update([], at: 1.1), [.click(.right)])
    }
}
