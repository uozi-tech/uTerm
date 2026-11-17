import GhosttyTerminal
import IOSurface
import QuartzCore
import UIKit

/// 切回一个 surface 被放掉过的终端标签时，盖在画面上的「上一帧」。
///
/// surface 放掉后，GhosttyKit 留在视图上的最后一帧（`IOSurfaceLayer` 的 contents）原样不动；重建出来的新层叠在它上面，
/// 头几帧是个空终端（只有光标）、行高还没按「按行填满」调回，等从影子回放完、行高调好才是对的画面。
/// 实测（迁移日志「切回标签闪烁」）：旧帧 → 空终端（两帧）→ 回放后的内容，用户看到的就是闪。
///
/// 这里在重建之前把旧帧**拷贝**一份（像素独立，不跟引擎的交换链走）放到一个普通 `CALayer` 盖在最上面，等新 surface 就绪、
/// 布局落地、几何安静下来才撤。撤盖看的是用户眼里的几何，不是帧数：
///
/// - 容器还有没落地的布局（等停稳、尺寸 / 字号没跟上）、按行填满的重算还没跑、视图 / 网格 / 行高调整 / 字号还在变，一律继续盖着；
///   这些都稳定了再等 `quietTime`，让引擎把对的那一帧交出来（尺寸 / 字号改完之后引擎会先交一两张半截几何的帧：
///   新字号配旧行距、新网格配旧行高）。
/// - 盖子必须在容器提交新尺寸之前装上（`GhosttyTerminalBridge.prepareSwitchBack`），否则量到的是提交后的 frame，旧帧被裁 / 挪位。
/// - 盖子里是旧帧的拷贝：没放掉 surface 时旧层还是活的，它的 IOSurface 随时被引擎的下一帧原地改写，直接引用的话盖子会跟着变。
///
/// 撤不掉的情况（后台、远端迟迟不对齐）由超时兜底。
///
/// 也用在容器提交新尺寸、视图要挪位置的时候（键盘升降：等停稳期间视图按旧尺寸挪着放，提交时挪回来）：引擎层上那张还没换掉的
/// 旧帧会跟着视图一起挪、按顶边对齐露出来，就是按键条上方闪一下旧内容。这时盖子留在屏上原处（`keepOnScreen`）。
@MainActor
final class GhosttySwitchBackCover {
    static let layerName = "uterm.switchback.cover"
    /// 就绪、布局落地、几何不再变化之后再等多久才撤：回放写进去、行高调整落地、引擎的半截几何帧交完，第一张对的帧才上屏。
    /// 按时间不按帧数：ProMotion 下一帧只有 8 ms。
    static let quietTime: CFTimeInterval = 0.06
    /// 最长盖多久。
    static let timeout: CFTimeInterval = 0.8

    private let cover = UIView()
    /// 旧帧本身。起初铺满盖子；视图挪了位置后盖子铺满视图、它留在屏上原处。
    private let image = CALayer()
    private weak var bridge: GhosttyTerminalBridge?
    private var link: CADisplayLink?
    private var quietSince: CFTimeInterval
    private var lastGeometry: Geometry?
    private let deadline: CFTimeInterval

    /// 用户眼里的几何：视图的位置尺寸、字号、行高调整、网格与格子像素、按行填满的下移量。任何一项在变，就还没稳。
    private struct Geometry: Equatable {
        var frame: CGRect
        var fontSize: CGFloat
        var adjustment: Int
        var grid: [Int]
        var rowFillOffset: CGFloat
    }

    /// 视图上现有的、带画面的 `IOSurfaceLayer` 里最后一个（最新）。没有（从没画过）返回 nil。
    static func surfaceLayers(in root: CALayer) -> [CALayer] {
        var found: [CALayer] = []
        if NSStringFromClass(type(of: root)).contains("IOSurface") { found.append(root) }
        for sub in root.sublayers ?? [] { found += surfaceLayers(in: sub) }
        return found
    }

    /// 盖上旧帧。没有旧帧可盖时返回 nil。盖子是终端视图的一个子 **UIView**，不是裸 `CALayer`：引擎的视图每次布局 / 出帧都会把
    /// 自己名下的裸子层铺满 bounds、改写 `contentsScale`（`enforceSublayerScale`，只放过 delegate 是 UIView 的层），
    /// 裸子层的盖子就会随视图改尺寸被拉 / 裁。
    static func install(on bridge: GhosttyTerminalBridge) -> GhosttySwitchBackCover? {
        let view = bridge.view
        guard let stale = surfaceLayers(in: view.layer).last(where: { $0.contents != nil }) else { return nil }
        return GhosttySwitchBackCover(copying: stale, root: view.layer, bridge: bridge)
    }

    private init(copying stale: CALayer, root: CALayer, bridge: GhosttyTerminalBridge) {
        self.bridge = bridge
        deadline = CACurrentMediaTime() + Self.timeout
        quietSince = CACurrentMediaTime()
        cover.isUserInteractionEnabled = false
        cover.isOpaque = true
        cover.translatesAutoresizingMaskIntoConstraints = true
        cover.autoresizingMask = []
        cover.layer.name = Self.layerName
        image.contents = Self.copy(of: stale.contents)
        image.contentsGravity = stale.contentsGravity
        image.contentsScale = stale.contentsScale
        image.contentsRect = stale.contentsRect
        image.isOpaque = true
        cover.frame = stale.superlayer?.convert(stale.frame, to: root) ?? root.bounds
        image.frame = cover.bounds
        cover.layer.addSublayer(image)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bridge.view.addSubview(cover)
        CATransaction.commit()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick() {
        let now = CACurrentMediaTime()
        guard let bridge, bridge.isOnScreen, bridge.view.superview != nil, cover.superview === bridge.view,
              now < deadline else { return remove() }
        let view = bridge.view
        let pump = bridge.outputPump
        let grid = bridge.session.surfaceGrid
        let geometry = Geometry(frame: view.frame, fontSize: view.terminalFontSize, adjustment: view.uTermCellHeightAdjustment,
                                grid: grid.map { [Int($0.columns), Int($0.rows), Int($0.cellWidthPixels), Int($0.cellHeightPixels),
                                                  Int($0.widthPixels), Int($0.heightPixels)] } ?? [],
                                rowFillOffset: bridge.link.rowFillOffset)
        let settled = view.surface != nil && !view.uTermIsSurfaceReleased && bridge.isSurfaceReady
            && pump.isFeedingSurface && !pump.surfaceNeedsCatchUp
            && !bridge.geometryPending() && !bridge.link.rowFillRefitPending
        if !settled || geometry != lastGeometry { quietSince = now }
        lastGeometry = geometry
        if now - quietSince >= Self.quietTime { remove() }
    }

    /// 终端视图挪了 `dy`（容器提交新尺寸）：旧帧留在屏上原处，盖子铺满视图，旧帧之外用终端底色填——提交前那里就是空白，
    /// 不能让引擎层上还没换掉的旧画面（随视图挪了位置）透出来。
    func keepOnScreen(viewMovedBy dy: CGFloat, background: UIColor) {
        guard link != nil, dy != 0, let view = bridge?.view, cover.superview === view else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let placed = cover.layer.convert(image.frame, to: view.layer).offsetBy(dx: 0, dy: -dy)
        cover.frame = view.bounds
        cover.backgroundColor = background
        image.frame = view.layer.convert(placed, to: cover.layer)
        CATransaction.commit()
    }

    /// 旧帧的独立拷贝（同尺寸、同像素格式、同色彩空间的新 IOSurface）。拿不到就退回原引用。
    private static func copy(of contents: Any?) -> Any? {
        guard let contents, CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID() else { return contents }
        let source = unsafeBitCast(contents as AnyObject, to: IOSurfaceRef.self)
        let height = IOSurfaceGetHeight(source)
        let stride = IOSurfaceGetBytesPerRow(source)
        let properties: [CFString: Any] = [
            kIOSurfaceWidth: IOSurfaceGetWidth(source), kIOSurfaceHeight: height,
            kIOSurfaceBytesPerElement: IOSurfaceGetBytesPerElement(source),
            kIOSurfacePixelFormat: IOSurfaceGetPixelFormat(source), kIOSurfaceBytesPerRow: stride,
        ]
        guard let target = IOSurfaceCreate(properties as CFDictionary) else { return contents }
        IOSurfaceLock(source, .readOnly, nil)
        IOSurfaceLock(target, [], nil)
        let rowBytes = min(stride, IOSurfaceGetBytesPerRow(target))
        let from = IOSurfaceGetBaseAddress(source), to = IOSurfaceGetBaseAddress(target)
        for row in 0..<height { memcpy(to + row * IOSurfaceGetBytesPerRow(target), from + row * stride, rowBytes) }
        IOSurfaceUnlock(target, [], nil)
        IOSurfaceUnlock(source, .readOnly, nil)
        if let space = IOSurfaceCopyValue(source, kIOSurfaceColorSpace) { IOSurfaceSetValue(target, kIOSurfaceColorSpace, space) }
        return target
    }

    /// 撤掉盖子；顺手把被新层取代的旧层的画面丢掉（放掉 surface 本来是为了省那张帧缓冲）。
    func remove() {
        guard link != nil else { return }
        link?.invalidate()
        link = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cover.removeFromSuperview()
        if let root = bridge?.view.layer {
            let layers = Self.surfaceLayers(in: root)
            if layers.count > 1 { layers.dropLast().forEach { $0.contents = nil } }
        }
        CATransaction.commit()
        bridge?.coverRemoved(self)
    }
}
