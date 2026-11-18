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

/// 盯着送去显示的整块画面的像素数，变了就报一声（第一帧也报）。只在送显示的队列上用。
nonisolated final class RemoteFrameShapeWatcher: @unchecked Sendable {
    private var width = 0
    private var height = 0
    private let changed: @Sendable (_ width: Int, _ height: Int) -> Void

    init(changed: @escaping @Sendable (_ width: Int, _ height: Int) -> Void) {
        self.changed = changed
    }

    func note(_ image: CVPixelBuffer) {
        let newWidth = CVPixelBufferGetWidth(image), newHeight = CVPixelBufferGetHeight(image)
        guard newWidth != width || newHeight != height else { return }
        width = newWidth
        height = newHeight
        changed(newWidth, newHeight)
    }
}

/// 把「解好的画面送去显示」挪出收帧的队列：收帧的队列只管解码和回确认，显示这一步在自己的队列上做，
/// 只留最新的一张——上一张还没显示完又来了新的，中间那张不显示了（每张解好的画面都是完整的，跳过不影响后面）。
///
/// 为什么：送显示之前可能要先放大（`RemoteDesktopUpscaler`，GPU 上几毫秒到几十毫秒）。它原先就在收帧的队列上
/// 同步做，画面一动（滚动，每秒五十来帧）后面的帧和它们的确认全排在它后面：Mac 看到确认迟迟不回，以为链路堵了，
/// 码率一路降、在途的帧占满名额，手机上延迟到 1.4 秒（2026-11-18 Duo 窗口模式滚动；同一时刻用大包压这条链路
/// 7.7 Mbps，延迟只有 9 ms，不是网络）。挪出来之后显示慢只会少显示几帧，不再拖住确认。
///
/// `settle`：显示完一张之后 `settleDelay` 里没有新的来，就拿最后那张调一次（给放大器补放大用）。
nonisolated final class RemoteDesktopPresenter: @unchecked Sendable {
    typealias Present = @Sendable (CVPixelBuffer, RemoteDesktopFrame) -> Void

    private let queue = DispatchQueue(label: "com.uozi.uTerm.remote.present", qos: .userInteractive)
    private let lock = NSLock()
    private var pending: (image: CVPixelBuffer, frame: RemoteDesktopFrame)?
    private var draining = false
    private var skippedCount = 0
    private let present: Present
    private let settle: Present?
    private let settleDelay: TimeInterval
    // 以下两个只在 `queue` 上读写。
    private var last: (image: CVPixelBuffer, frame: RemoteDesktopFrame)?
    private var generation = 0

    static let settleDelay: TimeInterval = 0.12

    init(settleDelay: TimeInterval = RemoteDesktopPresenter.settleDelay, present: @escaping Present, settle: Present? = nil) {
        self.present = present
        self.settle = settle
        self.settleDelay = settleDelay
    }

    /// 因为来不及显示被跳过的帧数。
    var skipped: Int {
        lock.lock()
        defer { lock.unlock() }
        return skippedCount
    }

    /// 在收帧的队列上调，立刻返回。
    func submit(_ image: CVPixelBuffer, _ frame: RemoteDesktopFrame) {
        lock.lock()
        if pending != nil { skippedCount += 1 }
        pending = (image, frame)
        let start = !draining
        draining = true
        lock.unlock()
        if start { queue.async { self.drain() } }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let next = pending else {
                draining = false
                lock.unlock()
                return
            }
            pending = nil
            lock.unlock()
            present(next.image, next.frame)
            guard settle != nil else { continue }
            last = next
            generation &+= 1
            let shown = generation
            queue.asyncAfter(deadline: .now() + settleDelay) { [weak self] in self?.settleIfIdle(shown) }
        }
    }

    private func settleIfIdle(_ shown: Int) {
        guard shown == generation, let last else { return }
        self.last = nil
        settle?(last.image, last.frame)
    }
}

@MainActor
extension RemoteDesktopSession {
    /// 画布接上这一路流：画面直接送进 `layer`，光标位置回主线程交给 `onCursor`。
    /// 画布拆除时调 `detachCanvas()`。
    ///
    /// `regionSpace`：放大后 Mac 只送来其中一块的帧（`RemoteDesktopFrame.region`）画在它里面。它是一个「单位坐标」
    /// 的图层（见 `RemoteDesktopRegionPlacement`），盖在 `layer` 上面；`layer` 留着最后一张整块的画面垫底。
    /// 不给就只认整块的帧（不支持放大取区域的画布）。
    ///
    /// `upscaler`：整块的帧比屏幕上要显示的像素少时先经它放大（见 `RemoteDesktopUpscaler`；画布把显示的像素数报给它）。
    /// 只取一块的帧不经它：那是 Mac 按原生像素送来的，本来就够密。
    func attachCanvas(_ layer: AVSampleBufferDisplayLayer, regionSpace: CALayer? = nil,
                      upscaler: RemoteDesktopUpscaler? = nil,
                      onCursor: @escaping @MainActor (RemoteDesktopCursor) -> Void) {
        let renderer = RemoteDesktopRenderer(layer.sampleBufferRenderer)
        let stage = regionSpace.map { RemoteDesktopRegionStage(space: $0) }
        // 送显示（连同放大）不在收帧的队列上做，见 `RemoteDesktopPresenter`。
        // 画面停下来了：滚动时原样显示的最后一张补放大一次。
        var settle: RemoteDesktopPresenter.Present?
        if let upscaler {
            settle = { image, frame in
                guard frame.region == nil, let sharp = upscaler.settle(image) else { return }
                renderer.enqueue(sharp)
            }
        }
        // 整块画面换了像素数（原地换尺寸后的第一帧）：先让主线程把等着它的几何套上，再把这一帧送进显示层，
        // 排版和画面前后差不出一帧（见 `RemoteDesktopSession.frameShown`）。
        let shape = RemoteFrameShapeWatcher { [weak self] width, height in
            DispatchQueue.main.sync { MainActor.assumeIsolated { self?.frameShown(width: width, height: height) } }
            // 再过一趟主线程：上面改的是数据，画布的排版要到主线程这一轮收尾时才真的提交。
            DispatchQueue.main.sync {}
        }
        let presenter = RemoteDesktopPresenter(present: { image, frame in
            if let region = frame.region, let stage {
                stage.present(image, region: region)
                return
            }
            shape.note(image)
            renderer.enqueue(upscaler?.process(image) ?? image)
            stage?.presentedWhole()
        }, settle: settle)
        receiver.setHandlers(
            onImage: { image, frame in presenter.submit(image, frame) },
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

/// 放大后那一块画面：两个图层轮着用，在解码队列上摆（显式事务，不带动画）。
///
/// 为什么要两个：图层的位置和它里面的画面走的是两条路——位置随事务马上生效，画面要等显示层自己换上去，前后差
/// 一两帧。只有一层时，Mac 换了一块（捏合途中每隔一小会儿换一次），旧画面会先被拉到新位置上一两帧才换成新的，
/// 看起来就是画面在闪（2026-11-17 真机）。所以换一块时把新画面送进另一层、摆在上面，旧的那层原地留着（内容和
/// 位置仍然对得上，只是旧了几十毫秒），等新的显示出来再收走。回到整块同理：整块的那张先送进底下的显示层，
/// 上面这两层过一会儿才收。
nonisolated final class RemoteDesktopRegionStage: @unchecked Sendable {
    /// 换下来的那层过多久收走：够新画面显示出来（一两帧）。收晚了没有害处，它被新的盖着。
    static let retireDelay: TimeInterval = 0.08

    private struct Slot {
        let layer: AVSampleBufferDisplayLayer
        let renderer: RemoteDesktopRenderer
        /// 这层此刻摆在哪一块上；nil = 收着（藏起来、里面是空的）。
        var region: RemoteDesktopRegion?
        /// 排着的「收走」认这个数：这层又被用上时加一，排着的那次就作废。
        var ticket = 0
    }

    private let lock = NSLock()
    private var slots: [Slot]
    /// 正在收画面的那一层。
    private var front: Int?

    /// 在 `space`（单位坐标的图层）里建两层。主线程上、画布接上会话时调；重复接上时换掉上一回建的。
    @MainActor init(space: CALayer) {
        space.sublayers?.forEach { $0.removeFromSuperlayer() }
        slots = (0..<2).map { _ in
            let layer = AVSampleBufferDisplayLayer()
            layer.videoGravity = .resize
            layer.isHidden = true
            space.addSublayer(layer)
            return Slot(layer: layer, renderer: RemoteDesktopRenderer(layer.sampleBufferRenderer))
        }
    }

    /// 一帧只画了 `region` 那一块的画面。
    func present(_ image: CVPixelBuffer, region: RemoteDesktopRegion) {
        lock.lock()
        defer { lock.unlock() }
        if let front, slots[front].region == region {
            slots[front].renderer.enqueue(image)
            return
        }
        // 换了一块：用另一层，优先挑收着的（里面是空的，露出来不会先闪一下上一回的画面）。
        let previous = front
        let next = slots.indices.first { $0 != previous && slots[$0].region == nil }
            ?? slots.indices.first { $0 != previous } ?? 0
        slots[next].ticket += 1
        slots[next].region = region
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        slots[next].layer.frame = RemoteDesktopRegionPlacement.frame(for: region)
        slots[next].layer.zPosition = 1
        slots[next].layer.isHidden = false
        if let previous { slots[previous].layer.zPosition = 0 }
        CATransaction.commit()
        slots[next].renderer.enqueue(image)
        front = next
        if let previous { retireSoon(previous) }
    }

    /// 来了一帧整块的画面（已经送进底下的显示层）：上面这两层等它显示出来再收。
    func presentedWhole() {
        lock.lock()
        defer { lock.unlock() }
        guard front != nil else { return }
        front = nil
        for index in slots.indices where slots[index].region != nil { retireSoon(index) }
    }

    /// 各层此刻摆在哪一块上（收着的为 nil）与正在收画面的那一层。测试用。
    var placement: (regions: [RemoteDesktopRegion?], front: Int?) {
        lock.lock()
        defer { lock.unlock() }
        return (slots.map(\.region), front)
    }

    private func retireSoon(_ index: Int) {
        slots[index].ticket += 1
        let ticket = slots[index].ticket
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + Self.retireDelay) { [weak self] in
            self?.retire(index, ticket: ticket)
        }
    }

    private func retire(_ index: Int, ticket: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard slots[index].ticket == ticket, slots[index].region != nil, front != index else { return }
        slots[index].region = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        slots[index].layer.isHidden = true
        CATransaction.commit()
        // 里面那张清掉：下次再露出来时不该先闪一下上一回的画面。
        slots[index].layer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
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
