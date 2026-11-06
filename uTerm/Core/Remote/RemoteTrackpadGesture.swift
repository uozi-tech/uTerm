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
}

/// 把触摸序列判定成触控板手势。
///
/// 一次触摸只有一个意图，判定后锁定到抬手，不会中途改变：
/// - 单指：移动超过 `moveThreshold` 走光标；不动地按住 `holdDuration` 开始拖拽；不动就抬起是单击。
/// - 没有「轻点拖移」（点一下紧接着按住拖）：点完马上接着滑是常见的操作，真机上它屡屡变成意外的拖拽、
///   把窗口拖走。拖拽只靠按住不动，与 Windows App 的鼠标指针模式一致。
/// - 双指：不动就抬起是右键；动了就看每根手指的方向选定滚动或捏合（规则见 `twoFingerIntent`）。
/// - 三指及以上：不产生动作，全部抬起后才接受新手势。
nonisolated struct RemoteTrackpadGesture {
    static let moveThreshold: CGFloat = 3
    static let holdDuration: TimeInterval = 0.45
    static let twoFingerTapDuration: TimeInterval = 0.35
    static let intentThreshold: CGFloat = 6
    /// 走不到这个距离的手指算还没起步：落指时接触点本身会晃几个点。
    static let fingerStillThreshold: CGFloat = 3
    /// 只有一根手指在动时，要走到这么远才下结论：另一根可能只是晚起步。
    static let oneFingerIntentThreshold: CGFloat = 16
    private static let velocityWindow: TimeInterval = 0.1

    private enum Phase {
        case idle
        case pendingOne(id: Int, start: CGPoint, startTime: TimeInterval)
        case pointer(id: Int)
        case drag(id: Int)
        case pendingTwo(first: RemoteTrackpadTouch, second: RemoteTrackpadTouch, startTime: TimeInterval, moved: Bool)
        case releasingTwo(id: Int, start: CGPoint, startTime: TimeInterval)
        case scrolling(ids: Set<Int>)
        case pinching(ids: Set<Int>, distance: CGFloat)
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
        return [.dragBegan]
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
        case .releasingTwo(let id, let start, let startTime):
            return advanceReleasingTwo(touches, id: id, start: start, startTime: startTime, at: time)
        case .scrolling(let ids):
            return advanceScrolling(touches, ids: ids, at: time)
        case .pinching(let ids, let distance):
            return advancePinching(touches, ids: ids, distance: distance, at: time)
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
            phase = .ignored
        }
        return []
    }

    private mutating func beginTwo(_ touches: [RemoteTrackpadTouch], at time: TimeInterval) {
        phase = .pendingTwo(first: touches[0], second: touches[1], startTime: time, moved: false)
    }

    private mutating func advancePendingOne(_ touches: [RemoteTrackpadTouch], id: Int, start: CGPoint,
                                            startTime: TimeInterval, at time: TimeInterval) -> [RemoteTrackpadAction] {
        if touches.isEmpty {
            phase = .idle
            return suppressesTap ? [] : [.click(.left)]
        }
        guard touches.count == 1, touches[0].id == id else {
            if touches.count == 2 { beginTwo(touches, at: time) } else { phase = .ignored }
            return []
        }
        let location = touches[0].location
        record(location, at: time)
        guard hypot(location.x - start.x, location.y - start.y) > Self.moveThreshold else { return [] }
        let delta = CGSize(width: location.x - start.x, height: location.y - start.y)
        tracked = location
        phase = .pointer(id: id)
        return [.movePointer(delta, speed: speed(at: time))]
    }

    private mutating func advancePointer(_ touches: [RemoteTrackpadTouch], id: Int,
                                         at time: TimeInterval) -> [RemoteTrackpadAction] {
        switch touches.count {
        case 0:
            phase = .idle
        case 2:
            beginTwo(touches, at: time)
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
        return [.dragMoved(delta, speed: speed(at: time), location: touch.location)]
    }

    private mutating func advancePendingTwo(_ touches: [RemoteTrackpadTouch], first: RemoteTrackpadTouch,
                                            second: RemoteTrackpadTouch, startTime: TimeInterval, moved: Bool,
                                            at time: TimeInterval) -> [RemoteTrackpadAction] {
        switch touches.count {
        case 0:
            phase = .idle
            return moved ? [] : twoFingerTap(startTime: startTime, at: time)
        case 1:
            phase = moved ? .ignored : .releasingTwo(id: touches[0].id, start: touches[0].location, startTime: startTime)
            return []
        default:
            break
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
            let start = Self.centroid([first, second])
            return [.scrollBegan, .scrollMoved(CGSize(width: center.x - start.x, height: center.y - start.y))]
        }
    }

    /// 真实的双指滚动不会同时起步，也不会完全平行，所以不能只比间距变化和整体位移：
    /// - 两根都在动：方向大致相同是滚动（哪怕一根走得多，间距也在变）；否则比间距变化和整体位移。
    /// - 只有一根在动：先等等，另一根可能只是晚起步。走够远还是这样，就看它是不是沿着双指连线在走。
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
            return stretch >= moved * 0.7 ? .pinch : .scroll
        }
        let alignment = (a.width * b.width + a.height * b.height) / (lengthA * lengthB)
        if alignment > 0.5 { return .scroll }
        return stretch >= travel ? .pinch : .scroll
    }

    private mutating func advanceReleasingTwo(_ touches: [RemoteTrackpadTouch], id: Int, start: CGPoint,
                                              startTime: TimeInterval, at time: TimeInterval) -> [RemoteTrackpadAction] {
        if touches.isEmpty {
            phase = .idle
            return twoFingerTap(startTime: startTime, at: time)
        }
        guard touches.count == 1, touches[0].id == id else {
            phase = .ignored
            return []
        }
        let location = touches[0].location
        if hypot(location.x - start.x, location.y - start.y) > Self.intentThreshold { phase = .ignored }
        return []
    }

    private func twoFingerTap(startTime: TimeInterval, at time: TimeInterval) -> [RemoteTrackpadAction] {
        guard !suppressesTap, time - startTime <= Self.twoFingerTapDuration else { return [] }
        return [.click(.right)]
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
        case .scrolling:
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
