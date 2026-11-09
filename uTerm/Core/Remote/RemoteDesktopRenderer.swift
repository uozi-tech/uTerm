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
    func attachCanvas(_ layer: AVSampleBufferDisplayLayer,
                      onCursor: @escaping @MainActor (RemoteDesktopCursor) -> Void) {
        let renderer = RemoteDesktopRenderer(layer.sampleBufferRenderer)
        receiver.setHandlers(
            onImage: { image, _ in renderer.enqueue(image) },
            onCursor: { cursor in
                DispatchQueue.main.async { MainActor.assumeIsolated { onCursor(cursor) } }
            })
    }

    func detachCanvas() {
        receiver.setHandlers(onImage: nil, onCursor: nil)
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
