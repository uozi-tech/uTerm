import AppKit
import CoreGraphics
import XCTest
@testable import uTerm

/// 窗口模式的「独立键鼠」：输入直接投给窗口所在的进程，不走全局输入通道（`RemoteWindowInputTarget`）。
/// 这里只核规则和事件上带的字段；真的投给后台窗口收不收得到，是带着远控进程身份的探针量的（见类型注释）。
final class RemoteWindowInputTests: XCTestCase {
    private typealias Window = RemoteDesktopWindows.Entry

    /// 记下投出去的事件和写进去的窗口内坐标。
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var posted: [(event: CGEvent, pid: pid_t)] = []
        private var locations: [ObjectIdentifier: CGPoint] = [:]
        private var listed = 0
        private var naps: [UInt64] = []
        var windows: [Window] = []
        var clock: UInt64 = 1_000_000_000

        var hooks: RemoteWindowInputTarget.Hooks {
            RemoteWindowInputTarget.Hooks(
                windows: { [self] pid in
                    lock.withLock { listed += 1 }
                    return windows.filter { $0.pid == pid }
                },
                window: { [self] id in windows.first { $0.id == id } },
                post: { [self] event, pid in lock.withLock { posted.append((event, pid)) } },
                setWindowLocation: { [self] event, point in lock.withLock { locations[ObjectIdentifier(event)] = point } },
                now: { [self] in clock },
                sleep: { [self] nanos in
                    lock.withLock { naps.append(nanos) }
                    clock += nanos
                })
        }

        var slept: [UInt64] { lock.withLock { naps } }

        var events: [CGEvent] { lock.withLock { posted.map(\.event) } }
        var pids: Set<pid_t> { lock.withLock { Set(posted.map(\.pid)) } }
        var listCount: Int { lock.withLock { listed } }
        func local(_ event: CGEvent) -> CGPoint? { lock.withLock { locations[ObjectIdentifier(event)] } }
        func clear() { lock.withLock { posted = [] } }
    }

    private final class PointLog: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [CGPoint] = []
        func add(_ point: CGPoint) { lock.withLock { stored.append(point) } }
        var points: [CGPoint] { lock.withLock { stored } }
    }

    private let pid: pid_t = 4242
    private let main: UInt32 = 42

    private func window(_ id: UInt32, _ bounds: CGRect, layer: Int = 0, pid: pid_t? = nil) -> Window {
        Window(id: id, pid: pid ?? self.pid, app: "App", title: "", bounds: bounds, layer: layer, alpha: 1)
    }

    private func makeTarget(front: Bool = false) -> (RemoteWindowInputTarget, Recorder) {
        let recorder = Recorder()
        recorder.windows = [window(main, CGRect(x: 100, y: 200, width: 800, height: 600))]
        let target = RemoteWindowInputTarget(windowID: main, pid: pid, isFront: front, source: nil, hooks: recorder.hooks)
        return (target, recorder)
    }

    private func mouse(_ type: CGEventType, at point: CGPoint) -> CGEvent {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)!
    }

    private func wheel(at point: CGPoint) -> CGEvent {
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -24, wheel2: 0, wheel3: 0)!
        event.location = point
        return event
    }

    private func field(_ event: CGEvent, _ raw: UInt32) -> Int64 {
        event.getIntegerValueField(CGEventField(rawValue: raw)!)
    }

    /// AppKit 内部事件的子类型：1 = App 被激活，2 = 退到后台。不是这种事件返回 nil。
    private func activationSubtype(_ event: CGEvent) -> Int? {
        guard let converted = NSEvent(cgEvent: event), converted.type == .appKitDefined else { return nil }
        return Int(converted.subtype.rawValue)
    }

    // MARK: - 寻址

    func test_click_is_addressed_to_the_window_and_posted_to_its_process() {
        let (target, recorder) = makeTarget(front: true)
        let point = CGPoint(x: 350, y: 420)
        target.deliverMouse(mouse(.leftMouseDown, at: point), at: point, phase: .down)
        target.deliverMouse(mouse(.leftMouseUp, at: point), at: point, phase: .up)
        XCTAssertEqual(recorder.events.map(\.type), [.mouseMoved, .leftMouseDown, .leftMouseUp],
                       "目标本来就是前台 App：不用先发「激活」；按下之前先移过去")
        XCTAssertEqual(recorder.pids, [pid])
        for event in recorder.events {
            XCTAssertEqual(event.getIntegerValueField(.mouseEventWindowUnderMousePointer), 42)
            XCTAssertEqual(event.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent), 42)
            XCTAssertEqual(event.getIntegerValueField(.eventTargetUnixProcessID), Int64(pid))
            XCTAssertEqual(field(event, 51), 42, "私有字段：窗口号")
            XCTAssertEqual(recorder.local(event), CGPoint(x: 250, y: 220), "窗口内坐标，左上角原点")
        }
        XCTAssertEqual(recorder.events[1].getDoubleValueField(.mouseEventPressure), 1)
        XCTAssertEqual(recorder.events[2].getDoubleValueField(.mouseEventPressure), 0)
    }

    func test_events_over_an_open_menu_go_to_the_menu_window() {
        let (target, recorder) = makeTarget(front: true)
        // 菜单是目标进程的另一个窗口，层级不是 0，排在看的窗口前面，可以伸到窗口外面。
        recorder.windows.insert(window(77, CGRect(x: 600, y: 700, width: 220, height: 240), layer: 101), at: 0)
        let onMenu = CGPoint(x: 650, y: 760)
        target.deliverMouse(mouse(.leftMouseDown, at: onMenu), at: onMenu, phase: .down)
        XCTAssertEqual(field(recorder.events[0], 51), 77)
        XCTAssertEqual(recorder.local(recorder.events[0]), CGPoint(x: 50, y: 60))
        // 同一次按键的拖动和抬起沿用按下时的那个窗口，哪怕指针已经离开它。
        let away = CGPoint(x: 300, y: 300)
        target.deliverMouse(mouse(.leftMouseDragged, at: away), at: away, phase: .drag)
        target.deliverMouse(mouse(.leftMouseUp, at: away), at: away, phase: .up)
        XCTAssertEqual(recorder.events.map { field($0, 51) }, [77, 77, 77, 77], "移过去、按下、拖动、抬起")
        // 下一次按在菜单外面：给看的窗口。
        target.deliverMouse(mouse(.leftMouseDown, at: away), at: away, phase: .down)
        XCTAssertEqual(field(recorder.events[4], 51), 42)
    }

    func test_resolve_only_accepts_attachments_in_front_of_the_window() {
        let target = window(42, CGRect(x: 100, y: 200, width: 800, height: 600))
        let point = CGPoint(x: 500, y: 500)
        // sheet：比看的窗口小、中心在它里面的普通窗口。
        let sheet = window(50, CGRect(x: 300, y: 250, width: 400, height: 300))
        XCTAssertEqual(RemoteWindowInputTarget.resolve(point: point, main: 42, in: [sheet, target])?.id, 50)
        // 同一个 App 的另一个文档窗口碰巧盖在上面：画面里没有它，点击落到看的窗口上。
        let sibling = window(51, CGRect(x: 0, y: 0, width: 1400, height: 900))
        XCTAssertEqual(RemoteWindowInputTarget.resolve(point: point, main: 42, in: [sibling, target])?.id, 42)
        let offset = window(52, CGRect(x: -300, y: 300, width: 700, height: 400))
        XCTAssertEqual(RemoteWindowInputTarget.resolve(point: CGPoint(x: 300, y: 500), main: 42, in: [offset, target])?.id, 42,
                       "中心在看的窗口外面：是另一个窗口，不是它的附属")
        // 同样大小、叠在同一个位置（两个浏览器窗口）：是另一个窗口。稍微错开一点的也是。
        let twin = window(54, target.bounds)
        XCTAssertEqual(RemoteWindowInputTarget.resolve(point: point, main: 42, in: [twin, target])?.id, 42)
        let cascaded = window(55, target.bounds.offsetBy(dx: 20, dy: 20))
        XCTAssertEqual(RemoteWindowInputTarget.resolve(point: point, main: 42, in: [cascaded, target])?.id, 42)
        // 排在看的窗口后面的不管。
        let menuBehind = window(53, CGRect(x: 400, y: 400, width: 300, height: 300), layer: 101)
        XCTAssertEqual(RemoteWindowInputTarget.resolve(point: point, main: 42, in: [target, menuBehind])?.id, 42)
        // 点不在附属窗口上：给看的窗口，哪怕点在它外面（菜单伸出去的那截之外）。
        XCTAssertEqual(RemoteWindowInputTarget.resolve(point: CGPoint(x: 10, y: 10), main: 42, in: [sheet, target])?.id, 42)
        XCTAssertNil(RemoteWindowInputTarget.resolve(point: point, main: 42, in: [sheet]), "看的窗口不在屏幕上")
    }

    func test_window_off_screen_still_receives_events_at_its_last_position() {
        // 窗口在别的桌面、或者最小化了：屏幕上的窗口表里没有它，照它自己的位置投。
        let recorder = Recorder()
        let hidden = window(main, CGRect(x: 100, y: 200, width: 800, height: 600))
        let target = RemoteWindowInputTarget(
            windowID: main, pid: pid, isFront: true, source: nil,
            hooks: RemoteWindowInputTarget.Hooks(windows: { _ in [] }, window: { _ in hidden },
                                                 post: recorder.hooks.post, setWindowLocation: recorder.hooks.setWindowLocation,
                                                 now: { 0 }, sleep: { _ in }))
        let point = CGPoint(x: 150, y: 260)
        target.deliverMouse(mouse(.leftMouseDown, at: point), at: point, phase: .down)
        XCTAssertEqual(recorder.events.map(\.type), [.mouseMoved, .leftMouseDown])
        XCTAssertEqual(recorder.local(recorder.events[1]), CGPoint(x: 50, y: 60))
    }

    func test_window_list_is_reused_for_moves_and_refreshed_on_press() {
        let (target, recorder) = makeTarget(front: true)
        let point = CGPoint(x: 300, y: 300)
        for _ in 0..<5 { target.deliverMouse(mouse(.mouseMoved, at: point), at: point, phase: .hover) }
        XCTAssertEqual(recorder.listCount, 1, "没按着键的移动沿用查到的窗口表")
        target.deliverMouse(mouse(.leftMouseDown, at: point), at: point, phase: .down)
        XCTAssertEqual(recorder.listCount, 2, "按下时重新查：菜单可能刚弹出来")
        recorder.clock += RemoteWindowInputTarget.windowListLifetimeNanos + 1
        target.deliverScroll(wheel(at: point), at: point)
        XCTAssertEqual(recorder.listCount, 3, "过期了重新查")
    }

    // MARK: - 激活

    func test_first_press_in_a_background_app_activates_it_and_swallows_the_first_mouse() throws {
        let (target, recorder) = makeTarget(front: false)
        let point = CGPoint(x: 350, y: 420)
        target.deliverMouse(mouse(.leftMouseDown, at: point), at: point, phase: .down)
        let events = recorder.events
        XCTAssertEqual(events.count, 5, "激活 + 窗口外垫的按下、抬起 + 移过去 + 真正的按下")
        XCTAssertEqual(activationSubtype(events[0]), 1, "先告诉目标「你被激活了」")
        XCTAssertEqual(field(events[0], 51), 42)
        // 垫的那一下点在窗口外面：不接受「激活窗口的那一下点击」的视图会把激活后的第一下丢掉，让它丢这一下。
        XCTAssertEqual(events[1].type, .leftMouseDown)
        XCTAssertEqual(events[2].type, .leftMouseUp)
        XCTAssertEqual(recorder.local(events[1]), CGPoint(x: -1, y: -1))
        XCTAssertEqual(recorder.local(events[2]), CGPoint(x: -1, y: -1))
        XCTAssertEqual(events[1].getIntegerValueField(.mouseEventNumber), events[2].getIntegerValueField(.mouseEventNumber))
        XCTAssertEqual(events[3].type, .mouseMoved)
        XCTAssertEqual(events[4].type, .leftMouseDown)
        XCTAssertEqual(recorder.local(events[4]), CGPoint(x: 250, y: 220))
        XCTAssertEqual(recorder.pids, [pid])

        // 之后不再发：重复的「激活」目标每次都会当真。
        recorder.clear()
        target.deliverMouse(mouse(.leftMouseUp, at: point), at: point, phase: .up)
        target.deliverMouse(mouse(.leftMouseDown, at: point), at: point, phase: .down)
        target.deliverKey(try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)))
        XCTAssertEqual(recorder.events.count, 3)
        XCTAssertTrue(recorder.events.allSatisfy { activationSubtype($0) == nil })
    }

    // MARK: - 像真鼠标

    func test_every_event_carries_the_current_time() throws {
        // 按时间戳算按了多久、双击间隔的实现要它是对的。私有字段 58 就是时间戳，读出来应该是同一个数。
        let (target, recorder) = makeTarget(front: false)
        let point = CGPoint(x: 350, y: 420)
        recorder.clock = 5_000_000_000
        target.deliverMouse(mouse(.leftMouseDown, at: point), at: point, phase: .down)
        recorder.clock = 5_200_000_000
        target.deliverMouse(mouse(.leftMouseUp, at: point), at: point, phase: .up)
        target.deliverScroll(wheel(at: point), at: point)
        target.deliverKey(try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)))
        target.finish()
        let stamps = recorder.events.map(\.timestamp)
        XCTAssertEqual(stamps.prefix(5), [5_000_000_000, 5_000_000_000, 5_000_000_000, 5_000_000_000, 5_000_000_000],
                       "激活、垫的两下、移过去、按下")
        XCTAssertEqual(Array(stamps.dropFirst(5)), [5_200_000_000, 5_200_000_000, 5_200_000_000, 5_200_000_000],
                       "抬起、滚轮、按键、撤掉激活")
        XCTAssertEqual(field(recorder.events[4], 58), 5_000_000_000)
        XCTAssertTrue(recorder.slept.isEmpty, "按了 200 ms：不用再等")
    }

    func test_press_is_preceded_by_a_move_unless_the_pointer_is_already_there() {
        // 真鼠标总是先到再按。触摸屏模式下一点就是按下，目标没见过指针到那儿。
        let (target, recorder) = makeTarget(front: true)
        let first = CGPoint(x: 350, y: 420), second = CGPoint(x: 600, y: 500)
        target.deliverMouse(mouse(.mouseMoved, at: first), at: first, phase: .hover)
        target.deliverMouse(mouse(.leftMouseDown, at: first), at: first, phase: .down)
        target.deliverMouse(mouse(.leftMouseUp, at: first), at: first, phase: .up)
        XCTAssertEqual(recorder.events.map(\.type), [.mouseMoved, .leftMouseDown, .leftMouseUp], "指针已经在那儿：不重复移")
        recorder.clear()
        target.deliverMouse(mouse(.leftMouseDown, at: second), at: second, phase: .down)
        XCTAssertEqual(recorder.events.map(\.type), [.mouseMoved, .leftMouseDown])
        XCTAssertEqual(recorder.events[0].location, second)
        XCTAssertEqual(recorder.local(recorder.events[0]), CGPoint(x: 500, y: 300))
        XCTAssertEqual(field(recorder.events[0], 51), 42)
    }

    func test_a_quick_tap_is_held_for_a_minimum_time() {
        // 手机上的一下轻点是按下、抬起紧挨着发的：按帧轮询状态的实现会漏掉，至少按住一小会儿。
        let (target, recorder) = makeTarget(front: true)
        let point = CGPoint(x: 350, y: 420)
        target.deliverMouse(mouse(.leftMouseDown, at: point), at: point, phase: .down)
        recorder.clock += 4_000_000
        target.deliverMouse(mouse(.leftMouseUp, at: point), at: point, phase: .up)
        XCTAssertEqual(recorder.slept, [RemoteWindowInputTarget.minimumPressNanos - 4_000_000])
        let events = recorder.events
        XCTAssertEqual(events.last?.type, .leftMouseUp)
        XCTAssertEqual(events.last.map { $0.timestamp - events[events.count - 2].timestamp },
                       RemoteWindowInputTarget.minimumPressNanos, "抬起的时间戳也是等完之后的")
        // 拖了一会儿才抬起：不等。
        target.deliverMouse(mouse(.leftMouseDown, at: point), at: point, phase: .down)
        recorder.clock += 80_000_000
        target.deliverMouse(mouse(.leftMouseUp, at: point), at: point, phase: .up)
        XCTAssertEqual(recorder.slept.count, 1)
    }

    func test_typing_activates_first_and_keys_are_not_window_addressed() throws {
        let (target, recorder) = makeTarget(front: false)
        target.deliverKey(try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)))
        let events = recorder.events
        XCTAssertEqual(events.count, 4, "系统文本框和中文输入要目标自以为是当前 App")
        XCTAssertEqual(activationSubtype(events[0]), 1)
        XCTAssertEqual(events[3].type, .keyDown)
        XCTAssertNil(recorder.local(events[3]), "键盘事件直接到第一响应者，不带窗口内坐标")
    }

    func test_moves_and_scrolling_do_not_activate() {
        let (target, recorder) = makeTarget(front: false)
        let point = CGPoint(x: 300, y: 300)
        target.deliverMouse(mouse(.mouseMoved, at: point), at: point, phase: .hover)
        target.deliverScroll(wheel(at: point), at: point)
        XCTAssertEqual(recorder.events.count, 2, "只是看看、滚一滚：不去动目标的激活状态")
        XCTAssertTrue(recorder.events.allSatisfy { activationSubtype($0) == nil && field($0, 51) == 42 })
    }

    func test_activation_is_redone_after_the_app_really_was_front_and_lost_it() {
        let (target, recorder) = makeTarget(front: false)
        let point = CGPoint(x: 350, y: 420)
        target.deliverMouse(mouse(.leftMouseDown, at: point), at: point, phase: .down)
        target.deliverMouse(mouse(.leftMouseUp, at: point), at: point, phase: .up)
        // 别的 App 之间来回切：和目标无关，不重发。
        target.frontApplicationChanged(to: 1)
        target.frontApplicationChanged(to: 2)
        recorder.clear()
        target.deliverMouse(mouse(.leftMouseDown, at: point), at: point, phase: .down)
        target.deliverMouse(mouse(.leftMouseUp, at: point), at: point, phase: .up)
        XCTAssertEqual(recorder.events.count, 2)
        // 坐在 Mac 前的人点了目标：它真的是前台 App，不用发。
        target.frontApplicationChanged(to: pid)
        recorder.clear()
        target.deliverMouse(mouse(.leftMouseDown, at: point), at: point, phase: .down)
        target.deliverMouse(mouse(.leftMouseUp, at: point), at: point, phase: .up)
        XCTAssertEqual(recorder.events.count, 2)
        // 又切到了别的 App：系统让目标退到了后台，我们之前发的不算数了，再发一次。
        target.frontApplicationChanged(to: 1)
        recorder.clear()
        target.deliverMouse(mouse(.leftMouseDown, at: point), at: point, phase: .down)
        XCTAssertEqual(recorder.events.count, 4)
        XCTAssertEqual(activationSubtype(recorder.events[0]), 1)
    }

    func test_finish_tells_the_app_it_is_no_longer_active_only_if_we_activated_it() {
        let point = CGPoint(x: 350, y: 420)
        // 没发过「激活」：什么都不用撤。
        var (target, recorder) = makeTarget(front: false)
        target.deliverMouse(mouse(.mouseMoved, at: point), at: point, phase: .hover)
        recorder.clear()
        target.finish()
        XCTAssertTrue(recorder.events.isEmpty)
        // 发过：告诉它退到后台了，窗口画回没激活的样子。
        (target, recorder) = makeTarget(front: false)
        target.deliverMouse(mouse(.leftMouseDown, at: point), at: point, phase: .down)
        recorder.clear()
        target.finish()
        XCTAssertEqual(recorder.events.count, 1)
        XCTAssertEqual(activationSubtype(recorder.events[0]), 2)
        recorder.clear()
        target.finish()
        XCTAssertTrue(recorder.events.isEmpty, "只撤一次")
        // 发过之后目标真的成了前台 App：它确实是激活的，不能告诉它退到后台了。
        (target, recorder) = makeTarget(front: false)
        target.deliverMouse(mouse(.leftMouseDown, at: point), at: point, phase: .down)
        target.frontApplicationChanged(to: pid)
        recorder.clear()
        target.finish()
        XCTAssertTrue(recorder.events.isEmpty)
    }

    // MARK: - 注入器接上投递目标

    private let display = RemoteDesktopDisplay(id: 1, bounds: CGRect(x: 100, y: 200, width: 800, height: 600),
                                               pixelWidth: 1600, pixelHeight: 1200, windowID: 42)

    func test_injector_routes_everything_to_the_window_and_keeps_its_own_pointer() {
        let (target, recorder) = makeTarget(front: true)
        let leaked = Recorder()
        let injector = RemoteEventInjector(display: display, windowTarget: target,
                                           hidPost: { leaked.hooks.post($0, 0) })
        XCTAssertEqual(injector.virtualPointer, CGPoint(x: 500, y: 500), "起点在窗口正中")
        injector.inject(.move(x: 0.25, y: 0.5))
        XCTAssertEqual(injector.virtualPointer, CGPoint(x: 300, y: 500), "Mac 上的指针不动，主控端的指针跟着这里走")
        injector.inject(.button(.left, down: true, clickCount: 1, x: 0.25, y: 0.5, modifiers: []))
        injector.inject(.move(x: 0.5, y: 0.5))
        injector.inject(.button(.left, down: false, clickCount: 1, x: 0.5, y: 0.5, modifiers: []))
        injector.inject(.scroll(dx: 0, dy: -24, phase: .changed))
        injector.inject(.key(code: 0, down: true, modifiers: []))
        injector.inject(.text("你好"))
        let types = recorder.events.map(\.type)
        XCTAssertEqual(types, [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .scrollWheel,
                               .keyDown, .keyDown, .keyUp])
        XCTAssertEqual(recorder.local(recorder.events[1]), CGPoint(x: 200, y: 300))
        XCTAssertEqual(recorder.local(recorder.events[2]), CGPoint(x: 400, y: 300))
        XCTAssertEqual(recorder.events[2].getDoubleValueField(.mouseEventPressure), 1, "拖动中")
        XCTAssertTrue(leaked.events.isEmpty, "没有一个事件走全局输入通道")
    }

    func test_stopping_releases_held_buttons_through_the_window_and_undoes_the_activation() {
        let (target, recorder) = makeTarget(front: false)
        let injector = RemoteEventInjector(display: display, windowTarget: target, hidPost: { _ in XCTFail("走了全局通道") })
        injector.inject(.button(.left, down: true, clickCount: 1, x: 0.5, y: 0.5, modifiers: []))
        recorder.clear()
        injector.releaseButtons()
        XCTAssertEqual(recorder.events.count, 2)
        XCTAssertEqual(recorder.events[0].type, .leftMouseUp)
        XCTAssertEqual(activationSubtype(recorder.events[1]), 2)
    }

    func test_global_channel_checks_what_covers_the_point_before_each_press() {
        // 主控端关了独立键鼠（或建不了投递目标）：走全局通道，按下之前先看这个点上是不是盖着别的 App 的窗口。
        let guarded = PointLog()
        let posted = Recorder()
        let injector = RemoteEventInjector(display: display, pressGuard: { guarded.add($0) },
                                           hidPost: { posted.hooks.post($0, 0) })
        XCTAssertNil(injector.virtualPointer, "走全局通道：主控端的指针跟着 Mac 的真实指针")
        injector.inject(.move(x: 0.5, y: 0.5))
        XCTAssertEqual(guarded.points, [])
        injector.inject(.button(.left, down: true, clickCount: 1, x: 0.25, y: 0.5, modifiers: []))
        XCTAssertEqual(guarded.points, [CGPoint(x: 300, y: 500)], "按下之前查一次，查的是按下的位置")
        injector.inject(.button(.left, down: false, clickCount: 1, x: 0.25, y: 0.5, modifiers: []))
        XCTAssertEqual(guarded.points.count, 1, "抬起不查")
        XCTAssertEqual(posted.events.map(\.type), [.mouseMoved, .leftMouseDown, .leftMouseUp])
    }

    // MARK: - 窗口表上的规则

    func test_obstruction_is_another_apps_ordinary_window_on_top_at_that_point() {
        let target = window(42, CGRect(x: 100, y: 200, width: 800, height: 600))
        let point = CGPoint(x: 500, y: 500)
        let other = window(60, CGRect(x: 400, y: 400, width: 500, height: 500), pid: 9)
        XCTAssertEqual(RemoteDesktopWindows.obstruction(to: pid, at: point, in: [other, target])?.id, 60)
        XCTAssertNil(RemoteDesktopWindows.obstruction(to: pid, at: point, in: [target, other]), "它在下面")
        XCTAssertNil(RemoteDesktopWindows.obstruction(to: pid, at: CGPoint(x: 150, y: 250), in: [other, target]), "没盖到这个点")
        // 别的进程不是普通层级的窗口（铺满屏幕的透明浮层、程序坞）：提窗口也盖不过，不算。
        let overlay = window(61, CGRect(x: 0, y: 0, width: 2000, height: 1200), layer: 25, pid: 9)
        XCTAssertNil(RemoteDesktopWindows.obstruction(to: pid, at: point, in: [overlay, target]))
        XCTAssertEqual(RemoteDesktopWindows.obstruction(to: pid, at: point, in: [overlay, other, target])?.id, 60)
        // 自己的菜单在最上面：不算被盖住。
        let menu = window(62, CGRect(x: 450, y: 450, width: 200, height: 200), layer: 101)
        XCTAssertNil(RemoteDesktopWindows.obstruction(to: pid, at: point, in: [menu, other, target]))
    }

    func test_sibling_above_means_another_ordinary_window_of_the_same_app_overlaps_it() {
        let target = window(42, CGRect(x: 100, y: 200, width: 800, height: 600))
        let sibling = window(43, CGRect(x: 300, y: 300, width: 800, height: 600))
        let other = window(60, CGRect(x: 0, y: 0, width: 2000, height: 1200), pid: 9)
        XCTAssertTrue(RemoteDesktopWindows.hasSiblingAbove(id: 42, in: [sibling, target]))
        XCTAssertFalse(RemoteDesktopWindows.hasSiblingAbove(id: 42, in: [target, sibling]))
        XCTAssertFalse(RemoteDesktopWindows.hasSiblingAbove(id: 42, in: [other, target]), "别的 App 盖着不用提：流照出、点击照到")
        let apart = window(44, CGRect(x: 1000, y: 900, width: 300, height: 200))
        XCTAssertFalse(RemoteDesktopWindows.hasSiblingAbove(id: 42, in: [apart, target]), "不重叠")
        XCTAssertFalse(RemoteDesktopWindows.hasSiblingAbove(id: 42, in: [sibling]), "窗口不在屏幕上")
    }
}
