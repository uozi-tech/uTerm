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

/// 「适配屏幕」与屏幕 / 窗口圆角同心（iOS 26 的同心原则）。
///
/// 画布铺满整屏（手机）或铺到窗口底边（Mac），四角落在屏幕 / 窗口的圆角里。普通的等比适配下画面的角
/// 如果落进了圆角弧线，画面不再缩到直角躲开弧线，而是离画布四边留一圈一样宽的窄边（`gap`）铺满，
/// 画面自己的角切成同心圆角：半径 = 外面的圆角 − 画面角离画布两边较远的那个距离。两个圆心重合（四边都
/// 只留 `gap` 时）或画面的圆心更靠里，画面的弧线就整个在外面的弧线以内。普通适配下角本来就在弧线外
///（另一个方向留着宽黑边）就照旧铺满、不留窄边，离外圆角比半径还远的角是直角。
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

    /// 适配时画面四边留的窄边：普通等比适配下画面的角落进了外圆角的弧线才留，否则 0。
    static func margin(content: CGSize, view: CGSize, corners: RemoteDesktopCornerRadii) -> CGFloat {
        guard corners.max > 0, content.width > 0, content.height > 0 else { return 0 }
        let full = min(view.width / content.width, view.height / content.height)
        let dx = (view.width - content.width * full) / 2, dy = (view.height - content.height * full) / 2
        // 居中：四个角离视图两边的距离都一样，只看最大的外圆角。
        return clears(dx: dx, dy: dy, radius: corners.max) ? 0 : gap
    }

    /// 适配比例（每个内容点占多少视图点）：等比放进四边各让出 `margin` 的视图。
    static func scale(content: CGSize, view: CGSize, corners: RemoteDesktopCornerRadii) -> CGFloat {
        guard content.width > 0, content.height > 0, view.width > 0, view.height > 0 else { return 1 }
        let margin = margin(content: content, view: view, corners: corners)
        let full = min(view.width / content.width, view.height / content.height)
        let inset = min(max(0, view.width - margin * 2) / content.width, max(0, view.height - margin * 2) / content.height)
        return inset > 0 ? inset : full
    }

    /// 画面（`frame`，视图坐标）四角的同心圆角。画面放大出了画布的角在屏幕外，不切。
    static func pictureCorners(frame: CGRect, view: CGSize, corners: RemoteDesktopCornerRadii) -> RemoteDesktopPictureCorners {
        let dx = min(frame.minX, view.width - frame.maxX)
        let dy = min(frame.minY, view.height - frame.maxY)
        guard dx >= -0.5, dy >= -0.5 else { return .square }
        let distance = max(0, dx, dy)
        func cut(_ outer: CGFloat) -> CGFloat { outer - distance }
        let radii = [corners.topLeft, corners.topRight, corners.bottomLeft, corners.bottomRight].map(cut)
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
