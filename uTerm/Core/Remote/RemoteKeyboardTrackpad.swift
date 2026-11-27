import CoreGraphics

/// 远程桌面里，手机软键盘的触控板（长按空格键后滑动）用来做什么。只存本机。
nonisolated enum RemoteKeyboardTrackpadMode: String, CaseIterable, Sendable {
    /// 移动 Mac 上的文字光标：位移换成方向键，和手机上在输入框里移动光标的手感一样。
    case caret
    /// 移动鼠标指针：和在画面上单指滑动一样。键盘挡住画面下半截时不用把手指伸到上面去。
    case pointer

    static let defaultValue: Self = .caret

    /// 偏好里存的值认不出来时按默认值。
    init(stored: String?) {
        self = stored.flatMap(Self.init(rawValue:)) ?? .defaultValue
    }
}

/// 按住键盘触控板这一次的位移怎么换成发给 Mac 的输入。
///
/// 系统经 `UITextInput` 的 `beginFloatingCursor(at:)` / `updateFloatingCursor(at:)` 报手指的位置（输入视图的坐标，
/// 起点是按住的那一刻），这里只看相邻两次之间的位移。
///
/// - 文字光标：横向攒够 `columnStep` 按一下 ←/→，纵向攒够 `rowStep` 按一下 ↑/↓，余数留到下一次。
///   步长随手指速度变：慢慢挪时位移只按 `slowGain` 计（约 20 点一个字，能一个字一个字地点到位），
///   快拖时按原样计（`columnStep` 一个字），中间按速度线性过渡。画面要隔一个来回才看到光标动，
///   固定的小步长一放慢就会冲过头。
///   往回拖时先丢掉那个方向攒着的余数：不然要先把上一段没用完的位移走回来才开始动，像慢了半拍。
///   横着拖的时候手指总会上下抖一点：按平滑后的方向判断，偏离主方向不到 `minorAxisRatio` 的那个分量不计，
///   不然拖着拖着就跳到上一行；真斜着拖时两个方向都走。
/// - 鼠标指针：原样交出位移和速度（点 / 秒），由画布按触控板的加速曲线移动指针。
nonisolated struct RemoteKeyboardTrackpad {
    /// 快拖时横向每走这么多点按一下 ←/→。
    static let columnStep: CGFloat = 10
    /// 快拖时纵向每走这么多点按一下 ↑/↓（一行比一个字高，也防止横着拖时误跳行）。
    static let rowStep: CGFloat = 20
    /// 慢慢挪时位移打的折扣：每个字要走 `columnStep / slowGain` 点。
    static let slowGain: CGFloat = 0.5
    /// 手指速度（点 / 秒）不到这个按慢计，到 `fastSpeed` 按快计，中间线性过渡。
    static let slowSpeed: CGFloat = 60
    static let fastSpeed: CGFloat = 400
    /// 速度平滑的权重：每段新测的速度占多少。系统一秒报 60～120 次，单次的速度很跳。
    static let speedSmoothing: CGFloat = 0.35
    /// 平滑方向里次要分量不到主要分量的这么多倍时，这一段的次要分量不计（约 22°）。
    static let minorAxisRatio: CGFloat = 0.4
    /// 方向平滑的权重：每段新位移占多少。抖动一正一负，平均下来接近 0。
    static let directionSmoothing: CGFloat = 0.3

    private var last: CGPoint
    private var lastTime: Double
    private var pending: CGSize = .zero
    private var direction: CGSize = .zero
    /// 平滑后的手指速度（点 / 秒）。按住时从 0 起：刚开始挪的那一下总是按慢的精细走。
    private var speed: CGFloat = 0

    init(at point: CGPoint, time: Double) {
        last = point
        lastTime = time
    }

    /// 文字光标：手指在 `time` 到了 `point`，要按的方向键（键码，按顺序）。
    mutating func arrows(to point: CGPoint, time: Double) -> [UInt16] {
        var delta = CGSize(width: point.x - last.x, height: point.y - last.y)
        let elapsed = time - lastTime
        last = point
        lastTime = time
        // 同一时刻报的两次（或时间倒着走）测不出速度，沿用上一次的。
        if elapsed > 0 {
            let measured = hypot(delta.width, delta.height) / CGFloat(elapsed)
            speed += (measured - speed) * Self.speedSmoothing
        }
        direction = CGSize(width: direction.width + (delta.width - direction.width) * Self.directionSmoothing,
                           height: direction.height + (delta.height - direction.height) * Self.directionSmoothing)
        let horizontal = abs(direction.width), vertical = abs(direction.height)
        if vertical < horizontal * Self.minorAxisRatio {
            delta.height = 0
        } else if horizontal < vertical * Self.minorAxisRatio {
            delta.width = 0
        }
        // 看平滑后的方向：慢慢挪时手指一抖就有一两次反向的小位移，按单次判断会把攒着的清掉、一直走不满一格。
        if direction.width * pending.width < 0 { pending.width = 0 }
        if direction.height * pending.height < 0 { pending.height = 0 }
        let gain = Self.gain(at: speed)
        pending.width += delta.width * gain
        pending.height += delta.height * gain

        let columns = Int(pending.width / Self.columnStep)
        let rows = Int(pending.height / Self.rowStep)
        pending.width -= CGFloat(columns) * Self.columnStep
        pending.height -= CGFloat(rows) * Self.rowStep

        let horizontalKey = columns > 0 ? RemoteKeyMap.Key.right : RemoteKeyMap.Key.left
        let verticalKey = rows > 0 ? RemoteKeyMap.Key.down : RemoteKeyMap.Key.up
        return Array(repeating: horizontalKey, count: abs(columns)) + Array(repeating: verticalKey, count: abs(rows))
    }

    /// 手指速度 `speed`（点 / 秒）时位移按多少计。
    static func gain(at speed: CGFloat) -> CGFloat {
        let progress = min(max((speed - slowSpeed) / (fastSpeed - slowSpeed), 0), 1)
        return slowGain + (1 - slowGain) * progress
    }

    /// 鼠标指针：手指在 `time` 到了 `point`，这一段的位移与速度（点 / 秒）。
    mutating func pointerMove(to point: CGPoint, time: Double) -> (delta: CGSize, speed: CGFloat) {
        let delta = CGSize(width: point.x - last.x, height: point.y - last.y)
        let elapsed = time - lastTime
        last = point
        lastTime = time
        let speed = elapsed > 0 ? hypot(delta.width, delta.height) / CGFloat(elapsed) : 0
        return (delta, speed)
    }
}
