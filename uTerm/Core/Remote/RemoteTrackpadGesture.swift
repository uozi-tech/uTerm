import CoreGraphics
import Foundation

/// 一根手指此刻的位置。`id` 在手指按下到抬起之间不变。
nonisolated struct RemoteTrackpadTouch: Equatable {
    let id: Int
    let location: CGPoint
}

/// 手势判定的结果，由画布落到指针、滚动和视口上。
nonisolated enum RemoteTrackpadAction: Equatable {
    case movePointer(CGSize, speed: CGFloat)
    case click(RemoteMouseButton)
    case dragBegan
    case dragMoved(CGSize, speed: CGFloat, location: CGPoint)
    case dragEnded
    case scrollBegan
    case scrollMoved(CGSize)
    case scrollEnded(velocity: CGPoint)
    case zoomed(by: CGFloat, anchor: CGPoint)
    case panned(CGSize)
    /// 三指扫了一下（手指走的方向），一次接触只发一次。
    case swiped(RemoteSwipeDirection)
    /// 触摸屏模式：把指针放到手指所在的位置（视图坐标）。紧跟在后面的点击 / 拖拽 / 滚动就落在这里。
    case pointerJumped(to: CGPoint)
}

/// 三指扫动的方向（手指走的方向）。
nonisolated enum RemoteSwipeDirection: Equatable {
    case left, right, up, down

    /// Mac 触控板三指扫动对应的系统快捷键：左右切换桌面（内容跟着手指走：手指往左是去右边那个桌面）、
    /// 上是调度中心、下是应用程序窗口。都是「系统设置 › 键盘 › 键盘快捷键 › 调度中心」里的默认键，
    /// 用户在那里改过就不灵。
    var shortcut: (code: UInt16, modifiers: RemoteKeyModifiers) {
        switch self {
        case .left: return (RemoteKeyMap.Key.right, .control)
        case .right: return (RemoteKeyMap.Key.left, .control)
        case .up: return (RemoteKeyMap.Key.up, .control)
        case .down: return (RemoteKeyMap.Key.down, .control)
        }
    }
}

/// 把触摸序列判定成触控板手势。
///
/// 一次触摸只有一个意图，判定后锁定到抬手，不会中途改变：
/// - 单指：移动超过 `moveThreshold` 走光标；不动地按住 `holdDuration` 开始拖拽；不动就抬起是单击。
/// - 没有「轻点拖移」（点一下紧接着按住拖）：点完马上接着滑是常见的操作，真机上它屡屡变成意外的拖拽、
///   把窗口拖走。拖拽只靠按住不动，与 Windows App 的鼠标指针模式一致。
/// - 双指：不动就抬起是右键；动了就看每根手指的方向选定滚动或捏合（规则见 `twoFingerIntent`）。
/// - 三指：一起走过 `swipeThreshold` 判成扫动，按主方向发一次 `swiped`，之后到全部抬起都不再有动作。
///   手指不会同时落下，单指 / 双指还没判定时来了第三根照样算三指。
/// - 四指及以上、三指中途抬起或加指：不产生动作，全部抬起后才接受新手势。
///
/// 触摸屏模式（`mode = .touch`，只看一个窗口时可选）：没有指针，点哪里就是哪里，像用手机上的 App。
/// - 单指轻点：在手指的位置单击。
/// - 单指拖动：滚动手指下面的内容（先把指针放到落指处，Mac 把滚动交给指针下面的视图）。
/// - 按住不动 `holdDuration`：在手指的位置按下左键，之后指针跟着手指走（选文字、拖滑块、拖窗口），抬手松开。
/// - 双指轻点：在两指中间右键。双指拖动、捏合、三指扫动与触控板模式相同。
/// 每个动作前先发 `pointerJumped`，后面跟的还是 `click` / `dragBegan` / `scrollBegan` 这些，画布照旧执行。
nonisolated struct RemoteTrackpadGesture {
    enum Mode {
        case trackpad
        case touch
    }

    /// 只在没有手势进行时改（调用方先 `cancel()`）。
    var mode = Mode.trackpad

    static let moveThreshold: CGFloat = 3
    /// 触摸屏模式下手指走出这么远才算拖动：直接点目标时手指落下、抬起之间会滑几个点，按触控板那 3 点算就全成了滚动。
    static let touchSlop: CGFloat = 10
    static let holdDuration: TimeInterval = 0.45
    static let twoFingerTapDuration: TimeInterval = 0.35
    static let intentThreshold: CGFloat = 6
    /// 走不到这个距离的手指算还没起步：落指时接触点本身会晃几个点。
    static let fingerStillThreshold: CGFloat = 3
    /// 只有一根手指在动时，要走到这么远才下结论：另一根可能只是晚起步。
    static let oneFingerIntentThreshold: CGFloat = 16
    /// 只有一根手指在动、而且沿着双指连线走时，要走到这么远才判成捏合：两指左右并排横着滚动正好也是沿连线走，
    /// 后面那根晚起步时同样只有一根在动，多等一段让它跟上。
    static let alongLineIntentThreshold: CGFloat = 32
    /// 另一根手指没「起步」（不到 `fingerStillThreshold`）但已被带着朝同一方向挪了这么多：是跟着滚，不是捏合的支点。
    static let followThreshold: CGFloat = 1.5
    /// 三指的中心走到这么远才算扫动。
    static let swipeThreshold: CGFloat = 40
    /// 主方向要比另一个方向大这么多倍，斜着扫不算。
    static let swipeDominance: CGFloat = 1.5
    private static let velocityWindow: TimeInterval = 0.1

    private enum Phase {
        case idle
        case pendingOne(id: Int, start: CGPoint, startTime: TimeInterval)
        case pointer(id: Int)
        case drag(id: Int)
        case pendingTwo(first: RemoteTrackpadTouch, second: RemoteTrackpadTouch, startTime: TimeInterval, moved: Bool)
        case releasingTwo(id: Int, start: CGPoint, startTime: TimeInterval, anchor: CGPoint)
        case scrolling(ids: Set<Int>)
        /// 触摸屏模式的单指滚动。
        case touchScrolling(id: Int)
        case pinching(ids: Set<Int>, distance: CGFloat)
        case pendingThree(ids: Set<Int>, start: CGPoint)
        case ignored
    }

    private enum TwoFingerIntent {
        case still
        case undecided
        case scroll
        case pinch
    }

    private var phase = Phase.idle
    private var tracked = CGPoint.zero
    private var samples: [(time: TimeInterval, point: CGPoint)] = []
    private var suppressesTap = false

    /// 还在等按住时长到点：调用方要持续调 `tick`。
    var needsTick: Bool {
        if case .pendingOne = phase { return true }
        return false
    }

    /// 这次接触是用来停住惯性的，不算点击。
    mutating func suppressNextTap() {
        suppressesTap = true
    }

    /// 触摸有变化时调用，`touches` 是此刻仍在屏幕上的全部手指。
    mutating func update(_ touches: [RemoteTrackpadTouch], at time: TimeInterval) -> [RemoteTrackpadAction] {
        let actions = advance(touches, at: time)
        if case .idle = phase { suppressesTap = false }
        return actions
    }

    /// 时间推进：判定按住。
    ///
    /// `fingerLifted`：系统已经知道这根手指抬起了，只是抬起事件还没送到画布（父视图上的手势识别器
    /// 会扣住 touchesEnded 等自己判定失败，主线程忙时也会晚到）。这时计时到点也不能按下左键：
    /// 那会把一次轻点变成按住，Mac 上的点击全成了长按。等抬起事件到了照常算单击。
    mutating func tick(at time: TimeInterval, fingerLifted: Bool = false) -> [RemoteTrackpadAction] {
        guard case .pendingOne(let id, let start, let startTime) = phase, !fingerLifted else { return [] }
        guard time - startTime >= Self.holdDuration else { return [] }
        phase = .drag(id: id)
        tracked = start
        return jump(to: start) + [.dragBegan]
    }

    /// 系统收走了触摸：结束进行中的手势，不产生点击。
    mutating func cancel() -> [RemoteTrackpadAction] {
        let actions = endingActions
        phase = .idle
        suppressesTap = false
        samples = []
        return actions
    }

    private mutating func advance(_ touches: [RemoteTrackpadTouch], at time: TimeInterval) -> [RemoteTrackpadAction] {
        switch phase {
        case .idle:
            return begin(touches, at: time)
        case .pendingOne(let id, let start, let startTime):
            return advancePendingOne(touches, id: id, start: start, startTime: startTime, at: time)
        case .pointer(let id):
            return advancePointer(touches, id: id, at: time)
        case .drag(let id):
            return advanceDrag(touches, id: id, at: time)
        case .pendingTwo(let first, let second, let startTime, let moved):
            return advancePendingTwo(touches, first: first, second: second, startTime: startTime, moved: moved, at: time)
        case .releasingTwo(let id, let start, let startTime, let anchor):
            return advanceReleasingTwo(touches, id: id, start: start, startTime: startTime, anchor: anchor, at: time)
        case .scrolling(let ids):
            return advanceScrolling(touches, ids: ids, at: time)
        case .touchScrolling(let id):
            return advanceTouchScrolling(touches, id: id, at: time)
        case .pinching(let ids, let distance):
            return advancePinching(touches, ids: ids, distance: distance, at: time)
        case .pendingThree(let ids, let start):
            return advancePendingThree(touches, ids: ids, start: start)
        case .ignored:
            if touches.isEmpty { phase = .idle }
            return []
        }
    }

    private mutating func begin(_ touches: [RemoteTrackpadTouch], at time: TimeInterval) -> [RemoteTrackpadAction] {
        switch touches.count {
        case 0:
            break
        case 1:
            let touch = touches[0]
            phase = .pendingOne(id: touch.id, start: touch.location, startTime: time)
            resetSamples(touch.location, at: time)
        case 2:
            beginTwo(touches, at: time)
        default:
            beginThreeOrIgnore(touches)
        }
        return []
    }

    private mutating func beginThreeOrIgnore(_ touches: [RemoteTrackpadTouch]) {
        guard touches.count == 3 else {
            phase = .ignored
            return
        }
        phase = .pendingThree(ids: Set(touches.map(\.id)), start: Self.centroid(touches))
    }

    private mutating func beginTwo(_ touches: [RemoteTrackpadTouch], at time: TimeInterval) {
        phase = .pendingTwo(first: touches[0], second: touches[1], startTime: time, moved: false)
    }

    private mutating func advancePendingOne(_ touches: [RemoteTrackpadTouch], id: Int, start: CGPoint,
                                            startTime: TimeInterval, at time: TimeInterval) -> [RemoteTrackpadAction] {
        if touches.isEmpty {
            phase = .idle
            return suppressesTap ? [] : jump(to: start) + [.click(.left)]
        }
        guard touches.count == 1, touches[0].id == id else {
            if touches.count == 2 { beginTwo(touches, at: time) } else { beginThreeOrIgnore(touches) }
            return []
        }
        let location = touches[0].location
        record(location, at: time)
        let slop = mode == .touch ? Self.touchSlop : Self.moveThreshold
        guard hypot(location.x - start.x, location.y - start.y) > slop else { return [] }
        let delta = CGSize(width: location.x - start.x, height: location.y - start.y)
        tracked = location
        if mode == .touch {
            // 判定用掉的位移一起发：内容从第一下就和手指对齐。
            phase = .touchScrolling(id: id)
            return [.pointerJumped(to: start), .scrollBegan, .scrollMoved(delta)]
        }
        phase = .pointer(id: id)
        return [.movePointer(delta, speed: speed(at: time))]
    }

    /// 触摸屏模式的单指滚动：只跟落下的那根手指，它抬起或又来了别的手指就结束。
    private mutating func advanceTouchScrolling(_ touches: [RemoteTrackpadTouch], id: Int,
                                                at time: TimeInterval) -> [RemoteTrackpadAction] {
        guard touches.count == 1, touches[0].id == id else {
            phase = touches.isEmpty ? .idle : .ignored
            return [.scrollEnded(velocity: velocity(at: time))]
        }
        record(touches[0].location, at: time)
        let delta = stepTracked(to: touches[0].location)
        return delta == .zero ? [] : [.scrollMoved(delta)]
    }

    /// 触摸屏模式下把指针放到这里；触控板模式什么也不发。
    private func jump(to point: CGPoint) -> [RemoteTrackpadAction] {
        mode == .touch ? [.pointerJumped(to: point)] : []
    }

    private mutating func advancePointer(_ touches: [RemoteTrackpadTouch], id: Int,
                                         at time: TimeInterval) -> [RemoteTrackpadAction] {
        switch touches.count {
        case 0:
            phase = .idle
        case 2:
            beginTwo(touches, at: time)
        case 3:
            beginThreeOrIgnore(touches)
        default:
            guard touches.count == 1, touches[0].id == id else {
                phase = .ignored
                return []
            }
            let location = touches[0].location
            record(location, at: time)
            let delta = stepTracked(to: location)
            if delta != .zero { return [.movePointer(delta, speed: speed(at: time))] }
        }
        return []
    }

    /// 拖拽只跟按下的那根手指：中途碰到别的手指不算结束，这根抬起才松开。
    private mutating func advanceDrag(_ touches: [RemoteTrackpadTouch], id: Int,
                                      at time: TimeInterval) -> [RemoteTrackpadAction] {
        guard let touch = touches.first(where: { $0.id == id }) else {
            phase = touches.isEmpty ? .idle : .ignored
            return [.dragEnded]
        }
        record(touch.location, at: time)
        let delta = stepTracked(to: touch.location)
        guard delta != .zero else { return [] }
        // 触摸屏模式：拖着的东西就在手指下面，不经指针加速。
        if mode == .touch { return [.pointerJumped(to: touch.location)] }
        return [.dragMoved(delta, speed: speed(at: time), location: touch.location)]
    }

    private mutating func advancePendingTwo(_ touches: [RemoteTrackpadTouch], first: RemoteTrackpadTouch,
                                            second: RemoteTrackpadTouch, startTime: TimeInterval, moved: Bool,
                                            at time: TimeInterval) -> [RemoteTrackpadAction] {
        let anchor = Self.centroid([first, second])
        switch touches.count {
        case 0:
            phase = .idle
            return moved ? [] : twoFingerTap(startTime: startTime, anchor: anchor, at: time)
        case 1:
            phase = moved ? .ignored : .releasingTwo(id: touches[0].id, start: touches[0].location,
                                                     startTime: startTime, anchor: anchor)
            return []
        default:
            break
        }
        if touches.count == 3, Set(touches.map(\.id)).isSuperset(of: [first.id, second.id]) {
            beginThreeOrIgnore(touches)
            return []
        }
        guard touches.count == 2,
              let firstNow = touches.first(where: { $0.id == first.id }),
              let secondNow = touches.first(where: { $0.id == second.id }) else {
            phase = .ignored
            return []
        }
        let current = [firstNow, secondNow]
        let center = Self.centroid(current)
        switch Self.twoFingerIntent(first: first, second: second, firstNow: firstNow, secondNow: secondNow) {
        case .still:
            return []
        case .undecided:
            phase = .pendingTwo(first: first, second: second, startTime: startTime, moved: true)
            return []
        case .pinch:
            phase = .pinching(ids: [first.id, second.id], distance: Self.distance(current))
            tracked = center
            return []
        case .scroll:
            phase = .scrolling(ids: [first.id, second.id])
            tracked = center
            resetSamples(center, at: time)
            // 判定用掉的位移一起发：内容从第一下就和手指对齐。
            return jump(to: anchor)
                + [.scrollBegan, .scrollMoved(CGSize(width: center.x - anchor.x, height: center.y - anchor.y))]
        }
    }

    /// 真实的双指滚动不会同时起步，也不会完全平行，所以不能只比间距变化和整体位移：
    /// - 两根都在动：方向大致相同是滚动（哪怕一根走得多，间距也在变）；否则比间距变化和整体位移。
    /// - 只有一根在动：先等等，另一根可能只是晚起步。走够远还是这样，就看它是不是沿着双指连线在走：
    ///   不沿连线是滚动；沿连线既可能是单指不动的捏合，也可能是两指左右并排横着滚、后面那根还没跟上——
    ///   另一根被带着朝同一方向挪了一点就是滚动，否则等走到 `alongLineIntentThreshold` 才判成捏合。
    private static func twoFingerIntent(first: RemoteTrackpadTouch, second: RemoteTrackpadTouch,
                                        firstNow: RemoteTrackpadTouch,
                                        secondNow: RemoteTrackpadTouch) -> TwoFingerIntent {
        let a = CGSize(width: firstNow.location.x - first.location.x, height: firstNow.location.y - first.location.y)
        let b = CGSize(width: secondNow.location.x - second.location.x, height: secondNow.location.y - second.location.y)
        let travel = hypot((a.width + b.width) / 2, (a.height + b.height) / 2)
        let stretch = abs(distance([firstNow, secondNow]) - distance([first, second]))
        guard max(travel, stretch) >= intentThreshold else { return .still }

        let lengthA = hypot(a.width, a.height)
        let lengthB = hypot(b.width, b.height)
        if min(lengthA, lengthB) < fingerStillThreshold {
            let moved = max(lengthA, lengthB)
            guard moved >= oneFingerIntentThreshold else { return .undecided }
            guard stretch >= moved * 0.7 else { return .scroll }
            let (lead, follower) = lengthA >= lengthB ? (a, b) : (b, a)
            let followed = hypot(follower.width, follower.height) >= followThreshold
                && lead.width * follower.width + lead.height * follower.height > 0
            if followed { return .scroll }
            return moved >= alongLineIntentThreshold ? .pinch : .undecided
        }
        let alignment = (a.width * b.width + a.height * b.height) / (lengthA * lengthB)
        if alignment > 0.5 { return .scroll }
        return stretch >= travel ? .pinch : .scroll
    }

    private mutating func advanceReleasingTwo(_ touches: [RemoteTrackpadTouch], id: Int, start: CGPoint,
                                              startTime: TimeInterval, anchor: CGPoint,
                                              at time: TimeInterval) -> [RemoteTrackpadAction] {
        if touches.isEmpty {
            phase = .idle
            return twoFingerTap(startTime: startTime, anchor: anchor, at: time)
        }
        guard touches.count == 1, touches[0].id == id else {
            phase = .ignored
            return []
        }
        let location = touches[0].location
        if hypot(location.x - start.x, location.y - start.y) > Self.intentThreshold { phase = .ignored }
        return []
    }

    /// 起点取第三根落下那一刻三指的中心：之前单指 / 双指没判定时走的那几点不算。
    private mutating func advancePendingThree(_ touches: [RemoteTrackpadTouch], ids: Set<Int>,
                                              start: CGPoint) -> [RemoteTrackpadAction] {
        guard touches.count == 3, Set(touches.map(\.id)) == ids else {
            phase = touches.isEmpty ? .idle : .ignored
            return []
        }
        guard let direction = Self.swipeDirection(from: start, to: Self.centroid(touches)) else { return [] }
        phase = .ignored
        return [.swiped(direction)]
    }

    static func swipeDirection(from start: CGPoint, to end: CGPoint) -> RemoteSwipeDirection? {
        let dx = end.x - start.x, dy = end.y - start.y
        guard hypot(dx, dy) >= swipeThreshold else { return nil }
        if abs(dx) >= abs(dy) * swipeDominance { return dx < 0 ? .left : .right }
        if abs(dy) >= abs(dx) * swipeDominance { return dy < 0 ? .up : .down }
        return nil
    }

    /// `anchor`：两指落下时的中点，触摸屏模式下右键点在这里。
    private func twoFingerTap(startTime: TimeInterval, anchor: CGPoint, at time: TimeInterval) -> [RemoteTrackpadAction] {
        guard !suppressesTap, time - startTime <= Self.twoFingerTapDuration else { return [] }
        return jump(to: anchor) + [.click(.right)]
    }

    private mutating func advanceScrolling(_ touches: [RemoteTrackpadTouch], ids: Set<Int>,
                                           at time: TimeInterval) -> [RemoteTrackpadAction] {
        guard touches.count == 2, Set(touches.map(\.id)) == ids else {
            phase = touches.isEmpty ? .idle : .ignored
            return [.scrollEnded(velocity: velocity(at: time))]
        }
        let center = Self.centroid(touches)
        record(center, at: time)
        let delta = stepTracked(to: center)
        return delta == .zero ? [] : [.scrollMoved(delta)]
    }

    private mutating func advancePinching(_ touches: [RemoteTrackpadTouch], ids: Set<Int>, distance: CGFloat,
                                          at time: TimeInterval) -> [RemoteTrackpadAction] {
        guard touches.count == 2, Set(touches.map(\.id)) == ids else {
            phase = touches.isEmpty ? .idle : .ignored
            return []
        }
        let center = Self.centroid(touches)
        let spread = Self.distance(touches)
        let delta = stepTracked(to: center)
        phase = .pinching(ids: ids, distance: spread)
        var actions: [RemoteTrackpadAction] = []
        if distance > 0, spread > 0, spread != distance { actions.append(.zoomed(by: spread / distance, anchor: center)) }
        if delta != .zero { actions.append(.panned(delta)) }
        return actions
    }

    private var endingActions: [RemoteTrackpadAction] {
        switch phase {
        case .drag:
            return [.dragEnded]
        case .scrolling, .touchScrolling:
            return [.scrollEnded(velocity: .zero)]
        default:
            return []
        }
    }

    // MARK: - 位移与速度

    private mutating func stepTracked(to point: CGPoint) -> CGSize {
        defer { tracked = point }
        return CGSize(width: point.x - tracked.x, height: point.y - tracked.y)
    }

    private mutating func resetSamples(_ point: CGPoint, at time: TimeInterval) {
        samples = [(time, point)]
    }

    private mutating func record(_ point: CGPoint, at time: TimeInterval) {
        samples.append((time, point))
        samples.removeAll { time - $0.time > Self.velocityWindow }
    }

    /// 最近一小段时间的平均速度。手指停下后再抬起，窗口里已没有移动，速度就是 0，不会甩出惯性。
    private func velocity(at time: TimeInterval) -> CGPoint {
        let recent = samples.filter { time - $0.time <= Self.velocityWindow }
        guard let first = recent.first, let last = recent.last, last.time > first.time else { return .zero }
        let duration = CGFloat(last.time - first.time)
        return CGPoint(x: (last.point.x - first.point.x) / duration, y: (last.point.y - first.point.y) / duration)
    }

    private func speed(at time: TimeInterval) -> CGFloat {
        let value = velocity(at: time)
        return hypot(value.x, value.y)
    }

    private static func centroid(_ touches: [RemoteTrackpadTouch]) -> CGPoint {
        let count = CGFloat(touches.count)
        return CGPoint(x: touches.reduce(0) { $0 + $1.location.x } / count,
                       y: touches.reduce(0) { $0 + $1.location.y } / count)
    }

    private static func distance(_ touches: [RemoteTrackpadTouch]) -> CGFloat {
        hypot(touches[0].location.x - touches[1].location.x, touches[0].location.y - touches[1].location.y)
    }
}
