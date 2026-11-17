import AVFoundation
import CoreGraphics

/// 把解好的画面送进显示层（手机与 Mac 主控端的画布共用）。
///
/// 在解码队列上用（`AVSampleBufferVideoRenderer` 可以在任意线程 enqueue）。渲染器出错、或系统要求 flush 才能
/// 继续解码（`requiresFlushToResumeDecoding`，App 切后台再回来、显示层换了窗口时会这样）时先记一笔原因，flush
/// 后把这一帧照常送进去：只看 `.failed` 会漏掉后一种，画面停在黑屏上等下一次变化。
nonisolated final class RemoteDesktopRenderer: @unchecked Sendable {
    let renderer: AVSampleBufferVideoRenderer
    private var failures = 0

    init(_ renderer: AVSampleBufferVideoRenderer) { self.renderer = renderer }

    func enqueue(_ image: CVPixelBuffer) {
        guard let sample = RemoteVideoDecoder.displaySample(image) else { return }
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            failures += 1
            if failures <= 20 || failures % 100 == 0 {
                let reason = renderer.error.map { "\($0)" } ?? "需要 flush"
                let count = failures
                AppLogger.info("远程桌面画布：渲染器出错，flush 后继续（第 \(count) 次）：\(reason)",
                               category: RemoteLog.category)
            }
            renderer.flush()
        }
        renderer.enqueue(sample)
    }
}

@MainActor
extension RemoteDesktopSession {
    /// 画布接上这一路流：画面直接送进 `layer`，光标位置回主线程交给 `onCursor`。
    /// 画布拆除时调 `detachCanvas()`。
    ///
    /// `regionLayer`：放大后 Mac 只送来其中一块的帧（`RemoteDesktopFrame.region`）画在它上面。它要放在一个
    /// 「单位坐标」的父图层里（见 `RemoteDesktopRegionPlacement`），盖在 `layer` 上面；`layer` 留着最后一张整块的
    /// 画面垫底。不给就只认整块的帧（不支持放大取区域的画布）。
    func attachCanvas(_ layer: AVSampleBufferDisplayLayer, regionLayer: AVSampleBufferDisplayLayer? = nil,
                      onCursor: @escaping @MainActor (RemoteDesktopCursor) -> Void) {
        let renderer = RemoteDesktopRenderer(layer.sampleBufferRenderer)
        let regional = regionLayer.map { (layer: RemoteDesktopRegionLayer($0), renderer: RemoteDesktopRenderer($0.sampleBufferRenderer)) }
        receiver.setHandlers(
            onImage: { image, frame in
                guard let regional else { return renderer.enqueue(image) }
                if let region = frame.region {
                    // 先把图层摆到这一帧画的那一块上，再送帧：两件事都在解码队列上做，不会有一帧画在旧位置上。
                    regional.layer.show(region)
                    regional.renderer.enqueue(image)
                } else {
                    regional.layer.hide()
                    renderer.enqueue(image)
                }
            },
            onCursor: { cursor in
                DispatchQueue.main.async { MainActor.assumeIsolated { onCursor(cursor) } }
            })
    }

    func detachCanvas() {
        receiver.setHandlers(onImage: nil, onCursor: nil)
    }
}

/// 放大后那一块画面的图层放在哪儿。
///
/// 父图层用「单位坐标」：bounds 固定是 `unit`×`unit`，代表整块显示器（或窗口），由画布按画面在屏幕上的位置和大小
/// 缩放、摆好。这样图层在父图层里的位置只由帧头里的区域决定，解码队列上就能摆，不用回主线程问画布的缩放。
nonisolated enum RemoteDesktopRegionPlacement {
    static let unit: CGFloat = 10_000

    static func frame(for region: RemoteDesktopRegion) -> CGRect {
        CGRect(x: region.x * unit, y: region.y * unit, width: region.width * unit, height: region.height * unit)
    }

    /// 把单位坐标的父图层摆成占满 `bounds`（画面区域自己的坐标）。在主线程上、画布排版时调。
    @MainActor static func layout(_ unitLayer: CALayer, in bounds: CGRect) {
        unitLayer.anchorPoint = .zero
        unitLayer.bounds = CGRect(x: 0, y: 0, width: unit, height: unit)
        unitLayer.position = bounds.origin
        unitLayer.setAffineTransform(CGAffineTransform(scaleX: bounds.width / unit, y: bounds.height / unit))
    }
}

/// 解码队列上摆那一块画面的图层（显式事务，不带动画）。
nonisolated final class RemoteDesktopRegionLayer: @unchecked Sendable {
    private let layer: AVSampleBufferDisplayLayer
    private var shown: RemoteDesktopRegion?

    init(_ layer: AVSampleBufferDisplayLayer) { self.layer = layer }

    func show(_ region: RemoteDesktopRegion) {
        guard region != shown else { return }
        shown = region
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = RemoteDesktopRegionPlacement.frame(for: region)
        layer.isHidden = false
        CATransaction.commit()
    }

    /// 回到整块：藏起来，并把里面那张清掉——下次再露出来时不该先闪一下上一回的画面。
    func hide() {
        guard shown != nil else { return }
        shown = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.isHidden = true
        CATransaction.commit()
        layer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    }
}

/// 两端画布上自己画的那个箭头光标（手机一直画；Mac 主控端在本机指针不在画面上时画）。
nonisolated enum RemoteDesktopArrowCursor {
    /// 尖端在原点，尺寸固定（视图点），不随缩放变。两端的画布都是 y 向下。
    static func path() -> CGPath {
        let path = CGMutablePath()
        path.move(to: .zero)
        path.addLine(to: CGPoint(x: 0, y: 17))
        path.addLine(to: CGPoint(x: 4.2, y: 13))
        path.addLine(to: CGPoint(x: 7.2, y: 19.5))
        path.addLine(to: CGPoint(x: 9.8, y: 18.3))
        path.addLine(to: CGPoint(x: 6.9, y: 12))
        path.addLine(to: CGPoint(x: 12.3, y: 12))
        path.closeSubpath()
        return path
    }
}
