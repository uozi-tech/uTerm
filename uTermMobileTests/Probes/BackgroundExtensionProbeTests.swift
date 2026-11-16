import AVFoundation
import CoreMedia
import UIKit
import XCTest
@testable import uTermMobile

/// 远程桌面角落滑开时的补色（`UIBackgroundExtensionView`，见 `RemoteDesktopCanvasView.extensionView`）：
/// 不滑开（内容正好铺满、没有要补的地方）时系统不挂任何补色图层；滑开时挂镜像 + 模糊，滑回去拆掉。
/// 2026-11-16 模拟器读数：平时 7 个图层（只多一个空的 CALayer）；滑开 11 个——3 个 CAPortalLayer
/// （左缝、角、下缝）+ 1 个铺满延伸区域的 CABackdropLayer（variableBlur）。
/// 截图验不了补出来的颜色（测试窗口不在前台场景，drawHierarchy 截不到），颜色在真机上看。
@MainActor
final class BackgroundExtensionProbeTests: XCTestCase {
    private func layerTree(_ layer: CALayer, depth: Int = 0) -> [String] {
        var lines = [String(repeating: "  ", count: depth) + "\(type(of: layer)) \(layer.frame.integral)"
            + (layer.isHidden ? " hidden" : "") + (layer.filters?.isEmpty == false ? " filters=\(layer.filters!)" : "")]
        for sub in layer.sublayers ?? [] { lines += layerTree(sub, depth: depth + 1) }
        return lines
    }

    private func greenSample() throws -> CMSampleBuffer {
        var buffer: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        CVPixelBufferCreate(nil, 64, 48, kCVPixelFormatType_32BGRA, attrs, &buffer)
        let image = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(image, [])
        let base = CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(image)
        for y in 0..<48 { for x in 0..<64 { let p = base + y * row + x * 4; p[0] = 0; p[1] = 200; p[2] = 0; p[3] = 255 } }
        CVPixelBufferUnlockBaseAddress(image, [])
        return try XCTUnwrap(RemoteVideoDecoder.displaySample(image))
    }

    private func count(_ name: String, in layer: CALayer) -> Int {
        (String(describing: type(of: layer)) == name ? 1 : 0) + (layer.sublayers ?? []).reduce(0) { $0 + count(name, in: $1) }
    }

    func test_extension_layers_and_fill() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("iOS 26 才有 UIBackgroundExtensionView") }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let root = UIViewController()
        root.view.backgroundColor = .black
        window.rootViewController = root
        window.isHidden = false

        let ext = UIBackgroundExtensionView()
        ext.automaticallyPlacesContentView = false
        let content = UIView()
        content.backgroundColor = .red  // 视频层没被延伸的话，缝里会是红的（只延伸了背景）
        let video = AVSampleBufferDisplayLayer()
        video.videoGravity = .resize
        content.layer.addSublayer(video)
        ext.contentView = content
        root.view.addSubview(ext)

        video.sampleBufferRenderer.enqueue(try greenSample())

        func place(contentFrame: CGRect) async {
            ext.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
            content.frame = contentFrame
            video.frame = content.bounds
            window.layoutIfNeeded()
            try? await Task.sleep(nanoseconds: 400_000_000)
        }

        // A：不滑开，内容正好铺满。
        await place(contentFrame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let treeA = layerTree(ext.layer)
        print("—— 不滑开（\(treeA.count) 个图层）\n" + treeA.joined(separator: "\n"))
        // 没有要补的地方：系统不挂镜像和模糊，平时零开销。
        XCTAssertEqual(count("CAPortalLayer", in: ext.layer), 0)
        XCTAssertEqual(count("CABackdropLayer", in: ext.layer), 0)

        // B：滑开，左边和下边各空出 20pt。
        await place(contentFrame: CGRect(x: 20, y: -20, width: 400, height: 300))
        let treeB = layerTree(ext.layer)
        print("—— 滑开（\(treeB.count) 个图层）\n" + treeB.joined(separator: "\n"))
        // 滑开：左缝、角、下缝各一个镜像（portal，渲染服务里直接复用画面，不拷像素），外加一层可变模糊。
        XCTAssertGreaterThan(count("CAPortalLayer", in: ext.layer), 0)
        XCTAssertEqual(count("CABackdropLayer", in: ext.layer), 1)

        // 回到 A，看补色用的图层会不会收回去。
        await place(contentFrame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let treeC = layerTree(ext.layer)
        print("—— 回到不滑开（\(treeC.count) 个图层）\n" + treeC.joined(separator: "\n"))
        // 滑回去后镜像和模糊都拆掉。
        XCTAssertEqual(count("CAPortalLayer", in: ext.layer), 0)
        XCTAssertEqual(count("CABackdropLayer", in: ext.layer), 0)
        window.isHidden = true
    }
}
