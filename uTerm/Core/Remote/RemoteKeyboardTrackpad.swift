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
/// - 文字光标：横向攒够 `columnStep` 按一下 ←/→，纵向攒够 `rowStep` 按一下 ↑/↓，余数留到下一次，来回拖动不丢步。
///   横着拖的时候手指总会上下抖一点：按平滑后的方向判断，偏离主方向不到 `minorAxisRatio` 的那个分量不计，
///   不然拖着拖着就跳到上一行；真斜着拖时两个方向都走。
/// - 鼠标指针：原样交出位移和速度（点 / 秒），由画布按触控板的加速曲线移动指针。
nonisolated struct RemoteKeyboardTrackpad {
    /// 横向每走这么多点按一下 ←/→（约等于手机上一个字的宽度）。
    static let columnStep: CGFloat = 9
    /// 纵向每走这么多点按一下 ↑/↓（一行比一个字高，也防止横着拖时误跳行）。
    static let rowStep: CGFloat = 18
    /// 平滑方向里次要分量不到主要分量的这么多倍时，这一段的次要分量不计（约 22°）。
    static let minorAxisRatio: CGFloat = 0.4
    /// 方向平滑的权重：每段新位移占多少。抖动一正一负，平均下来接近 0。
    static let directionSmoothing: CGFloat = 0.3

    private var last: CGPoint
    private var lastTime: Double
    private var pending: CGSize = .zero
    private var direction: CGSize = .zero

    init(at point: CGPoint, time: Double) {
        last = point
        lastTime = time
    }

    /// 文字光标：手指到了 `point`，要按的方向键（键码，按顺序）。
    mutating func arrows(to point: CGPoint) -> [UInt16] {
        var delta = CGSize(width: point.x - last.x, height: point.y - last.y)
        last = point
        direction = CGSize(width: direction.width + (delta.width - direction.width) * Self.directionSmoothing,
                           height: direction.height + (delta.height - direction.height) * Self.directionSmoothing)
        let horizontal = abs(direction.width), vertical = abs(direction.height)
        if vertical < horizontal * Self.minorAxisRatio {
            delta.height = 0
        } else if horizontal < vertical * Self.minorAxisRatio {
            delta.width = 0
        }
        pending.width += delta.width
        pending.height += delta.height

        let columns = Int(pending.width / Self.columnStep)
        let rows = Int(pending.height / Self.rowStep)
        pending.width -= CGFloat(columns) * Self.columnStep
        pending.height -= CGFloat(rows) * Self.rowStep

        let horizontalKey = columns > 0 ? RemoteKeyMap.Key.right : RemoteKeyMap.Key.left
        let verticalKey = rows > 0 ? RemoteKeyMap.Key.down : RemoteKeyMap.Key.up
        return Array(repeating: horizontalKey, count: abs(columns)) + Array(repeating: verticalKey, count: abs(rows))
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
