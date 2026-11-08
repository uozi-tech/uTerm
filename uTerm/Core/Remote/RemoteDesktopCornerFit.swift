import CoreGraphics

/// 「适配屏幕」避开圆角：画面等比居中放进视图，四个角都要在视图圆角的弧线以内。
///
/// 手机远程桌面的画布铺满整屏（放大、平移时圆角里的那点面积也用得上），Mac 的窗口也有圆角，
/// 只按视图的矩形适配时，画面四角正落进弧线里：菜单栏两头、Dock 两端被切掉。
/// 居中时四个角离视图边的距离相同，所以只看最大的那个圆角。
nonisolated enum RemoteDesktopCornerFit {
    /// 系统圆角是连续曲率（比同半径的圆弧更早开始弯），按放大的圆弧算，再留一点余量。
    static let continuousAllowance: CGFloat = 1.2
    static let slack: CGFloat = 1

    /// 内容一角离视图两边分别为 `dx`、`dy` 时，是否完全在半径 `radius` 的圆角之外。
    static func clears(dx: CGFloat, dy: CGFloat, radius: CGFloat) -> Bool {
        guard radius > 0 else { return true }
        let r = radius * continuousAllowance + slack
        if dx >= r || dy >= r { return true }
        let ox = r - dx, oy = r - dy
        return ox * ox + oy * oy <= r * r
    }

    /// 最大的适配比例（每个内容点占多少视图点）。没有圆角时就是普通的等比适配。
    static func scale(content: CGSize, view: CGSize, cornerRadius: CGFloat) -> CGFloat {
        guard content.width > 0, content.height > 0, view.width > 0, view.height > 0 else { return 1 }
        let full = min(view.width / content.width, view.height / content.height)
        func fits(_ s: CGFloat) -> Bool {
            clears(dx: (view.width - content.width * s) / 2, dy: (view.height - content.height * s) / 2,
                   radius: cornerRadius)
        }
        guard cornerRadius > 0, !fits(full) else { return full }
        // 比例越小两边留得越多，满足条件的比例是一段前缀：二分找边界。
        var low: CGFloat = 0, high = full
        for _ in 0..<40 {
            let mid = (low + high) / 2
            if fits(mid) { low = mid } else { high = mid }
        }
        return low
    }
}
