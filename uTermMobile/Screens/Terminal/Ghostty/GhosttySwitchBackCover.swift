import GhosttyTerminal
import QuartzCore
import UIKit

/// 切回一个 surface 被放掉过的终端标签时，盖在画面上的「上一帧」。
///
/// surface 放掉后，GhosttyKit 留在视图上的最后一帧（`IOSurfaceLayer` 的 contents）原样不动；重建出来的新层叠在它上面，
/// 头几帧是个空终端（只有光标）、行高还没按「按行填满」调回，等从影子回放完、行高调好才是对的画面。
/// 实测（迁移日志「切回标签闪烁」）：旧帧 → 空终端（两帧）→ 回放后的内容，用户看到的就是闪。
///
/// 这里在重建之前把旧帧拷到一个普通 `CALayer` 盖在最上面，等新 surface 就绪（建好、网格到位、回放追平、行高调好）再多等几帧让
/// 它交出对的帧，才撤掉。撤不掉的情况（后台、远端迟迟不对齐）由超时兜底。
@MainActor
final class GhosttySwitchBackCover {
    static let layerName = "uterm.switchback.cover"
    /// 就绪之后再等几个显示帧才撤：回放写进去、行高调整落地、第一张对的帧交出来都要时间。
    static let readyTicks = 5
    /// 最长盖多久。
    static let timeout: CFTimeInterval = 0.8

    private let layer = CALayer()
    private weak var bridge: GhosttyTerminalBridge?
    private var link: CADisplayLink?
    private var ready = 0
    private let deadline: CFTimeInterval

    /// 视图上现有的、带画面的 `IOSurfaceLayer` 里最后一个（最新）。没有（从没画过）返回 nil。
    static func surfaceLayers(in root: CALayer) -> [CALayer] {
        var found: [CALayer] = []
        if NSStringFromClass(type(of: root)).contains("IOSurface") { found.append(root) }
        for sub in root.sublayers ?? [] { found += surfaceLayers(in: sub) }
        return found
    }

    /// 盖上旧帧。没有旧帧可盖时返回 nil。
    static func install(on bridge: GhosttyTerminalBridge) -> GhosttySwitchBackCover? {
        let root = bridge.view.layer
        guard let stale = surfaceLayers(in: root).last(where: { $0.contents != nil }) else { return nil }
        return GhosttySwitchBackCover(copying: stale, root: root, bridge: bridge)
    }

    private init(copying stale: CALayer, root: CALayer, bridge: GhosttyTerminalBridge) {
        self.bridge = bridge
        deadline = CACurrentMediaTime() + Self.timeout
        layer.name = Self.layerName
        layer.contents = stale.contents
        layer.contentsGravity = stale.contentsGravity
        layer.contentsScale = stale.contentsScale
        layer.contentsRect = stale.contentsRect
        layer.isOpaque = true
        layer.zPosition = 1000
        layer.frame = stale.superlayer?.convert(stale.frame, to: root) ?? root.bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.addSublayer(layer)
        CATransaction.commit()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick() {
        guard let bridge, bridge.isOnScreen, bridge.view.superview != nil,
              CACurrentMediaTime() < deadline else { return remove() }
        let view = bridge.view
        let pump = bridge.outputPump
        let ok = view.surface != nil && !view.uTermIsSurfaceReleased && bridge.isSurfaceReady
            && pump.isFeedingSurface && !pump.surfaceNeedsCatchUp
        ready = ok ? ready + 1 : 0
        if ready >= Self.readyTicks { remove() }
    }

    /// 撤掉盖子；顺手把被新层取代的旧层的画面丢掉（放掉 surface 本来是为了省那张帧缓冲）。
    func remove() {
        guard link != nil else { return }
        link?.invalidate()
        link = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeFromSuperlayer()
        if let root = bridge?.view.layer {
            let layers = Self.surfaceLayers(in: root)
            if layers.count > 1 { layers.dropLast().forEach { $0.contents = nil } }
        }
        CATransaction.commit()
        bridge?.coverRemoved(self)
    }
}
