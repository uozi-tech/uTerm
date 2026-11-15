import CoreGraphics

/// 画布四个角各自落在多大的圆角里（视图点）：手机屏幕的物理圆角、Mac 窗口的圆角。0 = 直角。
nonisolated struct RemoteDesktopCornerRadii: Equatable {
    var topLeft: CGFloat = 0
    var topRight: CGFloat = 0
    var bottomLeft: CGFloat = 0
    var bottomRight: CGFloat = 0

    static let square = RemoteDesktopCornerRadii()

    init(topLeft: CGFloat = 0, topRight: CGFloat = 0, bottomLeft: CGFloat = 0, bottomRight: CGFloat = 0) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomLeft = bottomLeft
        self.bottomRight = bottomRight
    }

    init(all radius: CGFloat) {
        self.init(topLeft: radius, topRight: radius, bottomLeft: radius, bottomRight: radius)
    }

    var max: CGFloat { Swift.max(topLeft, topRight, bottomLeft, bottomRight) }
}

/// 画面四角的圆角：同一个半径，只切在 `corners` 里的那几个角上（`CALayer.maskedCorners` 的形状）。
nonisolated struct RemoteDesktopPictureCorners: Equatable {
    var radius: CGFloat
    var topLeft = false
    var topRight = false
    var bottomLeft = false
    var bottomRight = false

    static let square = RemoteDesktopPictureCorners(radius: 0)

    var isSquare: Bool { radius <= 0 || !(topLeft || topRight || bottomLeft || bottomRight) }
}

/// 「适配屏幕」躲开屏幕 / 窗口的圆角。
///
/// 画布铺满整屏（手机）或铺到窗口底边（Mac），四角落在屏幕 / 窗口的圆角里。普通的等比适配下画面的角
/// 如果落进了圆角弧线，按顺序试两种办法：
///
/// 1. **挪进黑边**：画面在某个方向比画布小（等比适配留下的黑边），就在这个方向上把画面往离圆角远的那头挪，
///    让两头的角各自躲开弧线，大小不变、角还是直角。尽量居中，只挪到刚好躲开为止。典型是 Duo 内屏上看 16:9
///    的外接屏：画布只有下面两个角是屏幕圆角，上下各有 ~50pt 黑边，画面往上挪一点就整块铺满宽度。
/// 2. **同心圆角**（iOS 26 的同心原则）：黑边不够挪，画面就离画布四边留一圈一样宽的窄边（`gap`）铺满，
///    自己的角切成同心圆角：半径 = 外面的圆角 − 画面角离画布两边较远的那个距离。两个圆心重合（四边都
///    只留 `gap` 时）或画面的圆心更靠里，画面的弧线就整个在外面的弧线以内。
///
/// 普通适配下角本来就在弧线外（另一个方向留着宽黑边）就照旧居中铺满，离外圆角比半径还远的角是直角。
nonisolated enum RemoteDesktopCornerFit {
    /// 画面离画布四边的窄边宽度（视图点）：与 `MBottomPanel` 离屏幕边的距离一致。
    static let gap: CGFloat = 8
    /// 判断画面的角在不在弧线里时，系统圆角是连续曲率（比同半径的圆弧更早开始弯），按放大的圆弧算。
    static let continuousAllowance: CGFloat = 1.2

    /// 直角的内容一角离视图两边分别为 `dx`、`dy` 时，是否完全在半径 `radius` 的（连续曲率）圆角之外。
    static func clears(dx: CGFloat, dy: CGFloat, radius: CGFloat) -> Bool {
        guard radius > 0 else { return true }
        let r = radius * continuousAllowance + 1
        if dx >= r || dy >= r { return true }
        let ox = r - dx, oy = r - dy
        return ox * ox + oy * oy <= r * r
    }

    /// 一个角在某个方向上至少要离边多远，才整个在（连续曲率）圆弧之外；它在另一个方向上离边 `other`。
    /// 和 `clears` 是同一个圆：`clears(other, 结果)` 正好成立。另一个方向出了视图（放大后）按贴边算：
    /// 角虽然出去了，画面那条边靠角的一段仍会被弧线切掉；也让放大时画面不在超出的那一刻跳回居中。
    static func clearance(other: CGFloat, radius: CGFloat) -> CGFloat {
        guard radius > 0 else { return 0 }
        let other = max(0, other)
        let r = radius * continuousAllowance + 1
        guard other < r else { return 0 }
        let o = r - other
        return r - (r * r - o * o).squareRoot()
    }

    /// 某个方向上画面离起点那条边多远：`slack` 是两头空余的总和，两头的角各要离边 `low` / `high` 才躲得开
    /// 圆弧。尽量居中，躲不开就往空的那头挪；两头加起来都不够时按要求的比例分（挪不开的角由同心圆角兜底）。
    static func offset(slack: CGFloat, low: CGFloat, high: CGFloat) -> CGFloat {
        guard slack > 0, low + high > 0 else { return slack / 2 }
        if low + high <= slack { return min(max(slack / 2, low), slack - high) }
        return slack * low / (low + high)
    }

    /// 尺寸为 `size` 的画面在视图里的左上角（只对比视图小的方向有意义，大的方向由视口按拖动位置定）。
    /// `shifts` 为 false 时居中（同心圆角那种适配：四边一样宽）。
    static func origin(size: CGSize, view: CGSize, corners: RemoteDesktopCornerRadii, shifts: Bool) -> CGPoint {
        let sx = view.width - size.width, sy = view.height - size.height
        guard shifts, corners.max > 0 else { return CGPoint(x: sx / 2, y: sy / 2) }
        // 算一个方向时，另一个方向按居中量离边多远（适配时那个方向贴边或比视图大，居中就是它的实际位置）。
        let dx = sx / 2, dy = sy / 2
        let top = max(clearance(other: dx, radius: corners.topLeft), clearance(other: dx, radius: corners.topRight))
        let bottom = max(clearance(other: dx, radius: corners.bottomLeft), clearance(other: dx, radius: corners.bottomRight))
        let left = max(clearance(other: dy, radius: corners.topLeft), clearance(other: dy, radius: corners.bottomLeft))
        let right = max(clearance(other: dy, radius: corners.topRight), clearance(other: dy, radius: corners.bottomRight))
        return CGPoint(x: offset(slack: sx, low: left, high: right), y: offset(slack: sy, low: top, high: bottom))
    }

    /// 画面（`frame`，视图坐标）的四个直角是否都在各自的外圆弧之外。
    static func clearsAll(frame: CGRect, view: CGSize, corners: RemoteDesktopCornerRadii) -> Bool {
        let left = frame.minX, right = view.width - frame.maxX, top = frame.minY, bottom = view.height - frame.maxY
        return clears(dx: left, dy: top, radius: corners.topLeft) && clears(dx: right, dy: top, radius: corners.topRight)
            && clears(dx: left, dy: bottom, radius: corners.bottomLeft)
            && clears(dx: right, dy: bottom, radius: corners.bottomRight)
    }

    /// 适配时画面四边留的窄边：普通等比适配下画面的角落进了外圆角的弧线、在黑边里挪也躲不开时才留，否则 0。
    static func margin(content: CGSize, view: CGSize, corners: RemoteDesktopCornerRadii) -> CGFloat {
        guard corners.max > 0, content.width > 0, content.height > 0 else { return 0 }
        let full = min(view.width / content.width, view.height / content.height)
        let size = CGSize(width: content.width * full, height: content.height * full)
        let placed = CGRect(origin: origin(size: size, view: view, corners: corners, shifts: true), size: size)
        return clearsAll(frame: placed, view: view, corners: corners) ? 0 : gap
    }

    /// 「适配屏幕」时画面在画布里最多能占多大：宽高比和它一样的画面正好铺满（角落进外圆角时四边各让出
    /// `gap`、切同心圆角，否则贴边）。无显示器的 Mac 按看的设备要的宽高比建虚拟屏，手机按这个比例要。
    static func fillSize(view: CGSize, corners: RemoteDesktopCornerRadii) -> CGSize {
        let margin = margin(content: view, view: view, corners: corners)
        return CGSize(width: max(0, view.width - margin * 2), height: max(0, view.height - margin * 2))
    }

    /// 适配比例（每个内容点占多少视图点）：等比放进四边各让出 `margin` 的视图。
    static func scale(content: CGSize, view: CGSize, corners: RemoteDesktopCornerRadii) -> CGFloat {
        guard content.width > 0, content.height > 0, view.width > 0, view.height > 0 else { return 1 }
        let margin = margin(content: content, view: view, corners: corners)
        let full = min(view.width / content.width, view.height / content.height)
        let inset = min(max(0, view.width - margin * 2) / content.width, max(0, view.height - margin * 2) / content.height)
        return inset > 0 ? inset : full
    }

    /// 画面（`frame`，视图坐标）四角的同心圆角。画面放大出了画布的角在屏幕外，不切；挪进黑边后离边够远的
    /// 角（每个角按它自己离两条边的距离算）也不切。
    static func pictureCorners(frame: CGRect, view: CGSize, corners: RemoteDesktopCornerRadii) -> RemoteDesktopPictureCorners {
        let left = frame.minX, right = view.width - frame.maxX, top = frame.minY, bottom = view.height - frame.maxY
        guard min(left, right) >= -0.5, min(top, bottom) >= -0.5 else { return .square }
        func cut(_ outer: CGFloat, _ dx: CGFloat, _ dy: CGFloat) -> CGFloat { outer - max(0, dx, dy) }
        let radii = [cut(corners.topLeft, left, top), cut(corners.topRight, right, top),
                     cut(corners.bottomLeft, left, bottom), cut(corners.bottomRight, right, bottom)]
        // CALayer 只有一个半径：取最大的那个。同一个框，半径越大切得越多、形状越往里收，所以对每个角
        // 都不会超出外面的弧线（取小的反而会让外圆角更大的那个角戳出去）。
        let positive = radii.filter { $0 > 0.5 }
        guard let radius = positive.max() else { return .square }
        return RemoteDesktopPictureCorners(radius: radius, topLeft: radii[0] > 0.5, topRight: radii[1] > 0.5,
                                           bottomLeft: radii[2] > 0.5, bottomRight: radii[3] > 0.5)
    }
}

#if canImport(QuartzCore)
import QuartzCore

extension CALayer {
    /// 把画面的同心圆角套到显示层上（两端的画布都是 y 向下：iOS 天生如此，Mac 的根层 `isGeometryFlipped`）。
    func applyRemoteDesktopCorners(_ corners: RemoteDesktopPictureCorners) {
        guard !corners.isSquare else {
            if cornerRadius != 0 { cornerRadius = 0 }
            if masksToBounds { masksToBounds = false }
            return
        }
        var mask: CACornerMask = []
        if corners.topLeft { mask.insert(.layerMinXMinYCorner) }
        if corners.topRight { mask.insert(.layerMaxXMinYCorner) }
        if corners.bottomLeft { mask.insert(.layerMinXMaxYCorner) }
        if corners.bottomRight { mask.insert(.layerMaxXMaxYCorner) }
        if cornerRadius != corners.radius { cornerRadius = corners.radius }
        if maskedCorners != mask { maskedCorners = mask }
        if cornerCurve != .continuous { cornerCurve = .continuous }
        if !masksToBounds { masksToBounds = true }
    }
}
#endif
