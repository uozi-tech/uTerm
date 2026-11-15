import CoreGraphics

/// 手机向 Mac 要多大的画面（`RemoteDesktopStartRequest.maxWidth` / `maxHeight`，与方向无关）。
///
/// 这个框有两个用处：接着显示器的 Mac 把屏幕等比套进去定视频尺寸；没接显示器的 Mac 按它的**宽高比**建虚拟屏
/// （`RemoteHeadlessDisplay`）。画面不是放在整块屏幕上，是放在顶栏下面的画布里，画布比屏幕扁：按整块屏幕的
/// 比例要，建出来的虚拟屏放进画布就左右留黑边（2026-11-15 Duo 内屏看无显示器的 mini：屏幕 1000×703.5pt，
/// 画布约 1000×646pt，截图里画面只有 860×630pt，左右各空 70pt）。所以比例按画布来：手机上「适配屏幕」是贴边
/// 铺满整块画布（`RemoteDesktopViewport.bleedsIntoCorners`），建出的虚拟屏正好不留黑边。大小仍不小于整块屏幕的
/// 像素：接着显示器的 Mac 上视频尺寸不比原来小。
///
/// Mac 的屏总是横的，一律按横过来看时的画布算：竖着开的，转过来之后也正好铺满。
nonisolated struct RemoteDesktopRequestSize: Equatable, Sendable {
    var width: Int
    var height: Int

    /// 竖着开时估横过来的顶栏：顶边距里超出这个值的部分是竖握才有的（状态栏、灵动岛），横过来就没有了。
    static let landscapeTopInset: CGFloat = 16

    /// 横过来看时顶栏下面的画布（宽 ≥ 高）。
    /// - Parameters:
    ///   - screen: 整块屏幕（视图点，现在的方向）。
    ///   - barHeight: 顶栏现在的高度，含它的顶边距 `topInset`。
    static func landscapeCanvas(screen: CGSize, barHeight: CGFloat, topInset: CGFloat) -> CGSize {
        let long = max(screen.width, screen.height), short = min(screen.width, screen.height)
        let portrait = screen.height > screen.width
        let bar = portrait ? barHeight - topInset + min(topInset, landscapeTopInset) : barHeight
        return CGSize(width: long, height: max(0, short - max(0, bar)))
    }

    /// - Parameter scale: 屏幕的像素倍数。
    static func fitting(screen: CGSize, scale: CGFloat, barHeight: CGFloat, topInset: CGFloat) -> RemoteDesktopRequestSize {
        let long = max(screen.width, screen.height), short = min(screen.width, screen.height)
        let box = RemoteDesktopSession.requestedSize(longPixels: Int(long * scale), shortPixels: Int(short * scale))
        let canvas = landscapeCanvas(screen: screen, barHeight: barHeight, topInset: topInset)
        // 画布量不出来（还没排版）：退回整块屏幕的像素。
        guard canvas.width > 0, canvas.height > 0, canvas.width >= canvas.height else {
            return RemoteDesktopRequestSize(width: box.width, height: box.height)
        }
        // 比例取画布的，大小取能盖住 `box` 的最小一块。画布比屏幕扁，通常是短边不动、长边加长。
        let aspect = canvas.width / canvas.height
        let height = max(CGFloat(box.height), (CGFloat(box.width) / aspect).rounded(.up))
        return RemoteDesktopRequestSize(width: Int((height * aspect).rounded()), height: Int(height))
    }
}
