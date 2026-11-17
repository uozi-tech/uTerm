import AppKit
import CoreGraphics
import CoreVideo
import XCTest
@testable import uTerm

/// 用真的 ScreenCaptureKit 按窗口采集：测试宿主自己开一个窗口，走生产的 `ScreenCaptureFrameSource`。
///
/// 要屏幕录制授权。测试宿主（开发签名的 uTerm）通常没有，没有就跳过，不弹系统授权框。要跑的话在
/// 「系统设置 › 隐私与安全性 › 录屏与系统录音」里给这份测试构建的 uTerm 打开开关。
@MainActor
final class RemoteDesktopWindowLiveTests: XCTestCase {
    func test_real_window_capture_lists_drops_static_frames_and_reports_resize() async throws {
        guard CGPreflightScreenCaptureAccess() else {
            throw XCTSkip("测试宿主没有屏幕录制授权，跳过真实采集")
        }
        let window = NSWindow(contentRect: NSRect(x: 240, y: 240, width: 400, height: 300),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "uTerm 窗口采集探针"
        let view = FillView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = view
        window.orderFrontRegardless()
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(600))

        // 1. 列表里有它，带着标题和点尺寸。
        let id = UInt32(window.windowNumber)
        let listed = try XCTUnwrap(RemoteDesktopWindows.list().first { $0.id == id }, "窗口不在可单独看的列表里")
        XCTAssertEqual(listed.title, "uTerm 窗口采集探针")
        XCTAssertEqual(listed.width, 400, accuracy: 1)

        // 2. 采集目标按窗口此刻的位置和所在显示器的倍数来。
        let target = try XCTUnwrap(RemoteDesktopWindows.target(id: id)).display
        XCTAssertEqual(target.windowID, id)
        XCTAssertEqual(target.bounds.width, 400, accuracy: 1)
        let scale = RemoteDesktopWindows.pixelScale(of: target.id)
        XCTAssertEqual(target.pixelWidth, Int((target.bounds.width * scale).rounded()))

        let size = RemoteDesktopGeometry.streamSize(
            displayPixels: CGSize(width: target.pixelWidth, height: target.pixelHeight), maxWidth: 4000, maxHeight: 4000)
        let source = ScreenCaptureFrameSource(display: target, width: size.width, height: size.height, tenBit: false)
        let frames = FrameLog()
        source.observeGeometry { frames.add($0) }
        try await source.start(onFrame: { image, _ in frames.add(image) }, onStop: { _ in })
        defer { source.stop() }

        // 3. 开流就有第一帧，尺寸是要的那个。
        let first = await waitUntil { frames.count >= 1 }
        XCTAssertTrue(first, "开始采集后应有第一帧")
        XCTAssertEqual(frames.lastSize?.width, size.width)
        XCTAssertEqual(frames.lastSize?.height, size.height)

        // 4. 画面不变：系统照样一帧帧地出（每秒几十帧），采集源比对后一张都不该再交。留一点余量给窗口刚出现时的重画。
        try await Task.sleep(for: .milliseconds(700))
        let settled = frames.count
        try await Task.sleep(for: .milliseconds(1500))
        XCTAssertLessThanOrEqual(frames.count - settled, 2, "静止 1.5 秒里交出了 \(frames.count - settled) 帧")

        // 5. 内容变了：马上有新帧。
        let beforeChange = frames.count
        view.color = .systemBlue
        view.needsDisplay = true
        let changed = await waitUntil { frames.count > beforeChange }
        XCTAssertTrue(changed, "窗口内容变了应有新帧")

        // 6. 窗口放大：流不断，报来新的范围，占比小于 1（新范围被缩进同一帧）。
        window.setContentSize(NSSize(width: 520, height: 380))
        let resized = await waitUntil { abs((frames.lastGeometry?.bounds.width ?? 0) - 520) <= 1 }
        XCTAssertTrue(resized, "窗口放大后应报新的范围：\(String(describing: frames.lastGeometry))")
        let geometry = try XCTUnwrap(frames.lastGeometry)
        XCTAssertLessThan(min(geometry.contentFraction.width, geometry.contentFraction.height), 0.99)
        XCTAssertEqual(geometry.bounds.width / geometry.bounds.height, window.frame.width / window.frame.height, accuracy: 0.02)
        XCTAssertEqual(frames.lastSize?.width, size.width, "视频帧的尺寸开流后不变")
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }
}

private final class FillView: NSView {
    var color = NSColor.systemRed
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        bounds.fill()
    }
}

/// 采集队列上记帧数、最后一帧的尺寸、最后一份几何。
private final class FrameLog: @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0
    private var size: (width: Int, height: Int)?
    private var geometry: RemoteDesktopFrameGeometry?

    func add(_ image: CVPixelBuffer) {
        lock.lock(); defer { lock.unlock() }
        frames += 1
        size = (CVPixelBufferGetWidth(image), CVPixelBufferGetHeight(image))
    }

    func add(_ geometry: RemoteDesktopFrameGeometry) {
        lock.lock(); defer { lock.unlock() }
        self.geometry = geometry
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return frames }
    var lastSize: (width: Int, height: Int)? { lock.lock(); defer { lock.unlock() }; return size }
    var lastGeometry: RemoteDesktopFrameGeometry? { lock.lock(); defer { lock.unlock() }; return geometry }
}
