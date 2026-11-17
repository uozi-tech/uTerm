import CoreGraphics
import CoreVideo
import XCTest
@preconcurrency import Network
@testable import uTerm

/// 远程桌面放大后按看得见的那一块取画面：该取哪一块、缩放器的裁切、帧头里的区域、请求从主控端到来源的一路。
@MainActor
final class RemoteDesktopRegionTests: XCTestCase {
    // MARK: - 该取哪一块

    func test_zoomed_view_gets_a_native_pixel_region_around_it() throws {
        // 4K 外接屏（4608×2592 像素）给手机 2853×1604 的视频：整块取时缩了 1.6 倍。
        let target = CGSize(width: 4608, height: 2592)
        let stream = (width: 2852, height: 1604)
        // 放大 4 倍看正中间：看得见 1152×648 像素，加余量也没视频帧大 → 取视频帧那么多像素，一比一。
        let visible = RemoteDesktopRegion(x: 0.375, y: 0.375, width: 0.25, height: 0.25)
        let region = try XCTUnwrap(RemoteDesktopRegionPolicy.captureRegion(visible: visible, current: nil,
                                                                           targetPixels: target, stream: stream))
        XCTAssertEqual(region.width * 4608, 2852, accuracy: 0.01, "一比一：取的像素数 = 视频帧的像素数")
        XCTAssertEqual(region.height * 2592, 1604, accuracy: 0.01)
        XCTAssertTrue(region.contains(visible))
        XCTAssertEqual(region.x + region.width / 2, 0.5, accuracy: 0.001, "以看得见的那块为中心")
        XCTAssertEqual((region.x * 4608).truncatingRemainder(dividingBy: 2), 0, accuracy: 1e-6, "落在偶数像素上")

        // 拖了一点、还在取的范围里：不换。
        let nudged = RemoteDesktopRegion(x: 0.42, y: 0.40, width: 0.25, height: 0.25)
        XCTAssertEqual(RemoteDesktopRegionPolicy.captureRegion(visible: nudged, current: region, targetPixels: target, stream: stream),
                       region)
        // 拖出去了：换一块，仍然一比一。
        let far = RemoteDesktopRegion(x: 0.7, y: 0.7, width: 0.25, height: 0.25)
        let moved = try XCTUnwrap(RemoteDesktopRegionPolicy.captureRegion(visible: far, current: region, targetPixels: target, stream: stream))
        XCTAssertNotEqual(moved, region)
        XCTAssertTrue(moved.contains(far))
        XCTAssertEqual(moved.width, region.width, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(moved.x + moved.width, 1 + 1e-9, "贴到边上，不出界")
        XCTAssertLessThanOrEqual(moved.y + moved.height, 1 + 1e-9)
    }

    func test_slight_zoom_or_whole_view_keeps_the_whole_picture() {
        let target = CGSize(width: 4608, height: 2592)
        let stream = (width: 2852, height: 1604)
        // 只放大一点点（看得见 80%）：加上余量快到整块了，不裁。
        XCTAssertNil(RemoteDesktopRegionPolicy.captureRegion(visible: RemoteDesktopRegion(x: 0.1, y: 0.1, width: 0.8, height: 0.8),
                                                             current: nil, targetPixels: target, stream: stream))
        XCTAssertNil(RemoteDesktopRegionPolicy.captureRegion(visible: .whole, current: nil, targetPixels: target, stream: stream))
        // 乱七八糟的输入：当没放大。
        XCTAssertNil(RemoteDesktopRegionPolicy.captureRegion(visible: RemoteDesktopRegion(x: .nan, y: 0, width: 0.2, height: 0.2),
                                                             current: nil, targetPixels: target, stream: stream))
        XCTAssertNil(RemoteDesktopRegionPolicy.captureRegion(visible: RemoteDesktopRegion(x: 0.5, y: 0.5, width: 0, height: 0.2),
                                                             current: nil, targetPixels: target, stream: stream))
    }

    func test_moderate_zoom_takes_the_visible_part_plus_margin() throws {
        let target = CGSize(width: 4608, height: 2592)
        let stream = (width: 2852, height: 1604)
        // 放大 1.5 倍：看得见 3072×1728 像素，比视频帧大。取看得见的加余量（每边 25%）→ 4608 的 100%，到整块了。
        XCTAssertNil(RemoteDesktopRegionPolicy.captureRegion(visible: RemoteDesktopRegion(x: 0.1, y: 0.1, width: 0.667, height: 0.667),
                                                             current: nil, targetPixels: target, stream: stream))
        // 放大 2 倍：看得见 2304×1296，加余量 3456×1944（75%），比视频帧大 → 还是缩，但比整块缩得少。
        let visible = RemoteDesktopRegion(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let region = try XCTUnwrap(RemoteDesktopRegionPolicy.captureRegion(visible: visible, current: nil, targetPixels: target, stream: stream))
        XCTAssertEqual(region.width * 4608, 3456, accuracy: 2)
        XCTAssertTrue(region.contains(visible))
        XCTAssertEqual(region.width * 4608 / (region.height * 2592), 2852.0 / 1604, accuracy: 0.01, "比例和视频帧一样")
    }

    func test_pixel_rect_respects_window_content_fraction() {
        let region = RemoteDesktopRegion(x: 0.5, y: 0.25, width: 0.25, height: 0.5)
        XCTAssertEqual(RemoteDesktopRegionPolicy.pixelRect(region, frameSize: CGSize(width: 4000, height: 2000)),
                       CGRect(x: 2000, y: 500, width: 1000, height: 1000))
        // 只看一个窗口、内容只占帧的左上 80%×90%：归一化坐标按内容那部分算。
        XCTAssertEqual(RemoteDesktopRegionPolicy.pixelRect(region, frameSize: CGSize(width: 4000, height: 2000),
                                                           contentFraction: CGSize(width: 0.8, height: 0.9)),
                       CGRect(x: 1600, y: 450, width: 800, height: 900))
    }

    func test_visible_region_and_mac_lens_frame() throws {
        // 手机：画面放大 2 倍、左上角对齐视图：看得见左上四分之一。
        let view = CGRect(x: 0, y: 0, width: 900, height: 600)
        let picture = CGRect(x: 0, y: 0, width: 1800, height: 1200)
        let visible = try XCTUnwrap(RemoteDesktopRegionPolicy.visibleRegion(picture: picture, view: view, zoom: 2))
        XCTAssertEqual(visible, RemoteDesktopRegion(x: 0, y: 0, width: 0.5, height: 0.5))
        // 没放大（或只放大一点点）不报；画面整个在视图外不报。
        XCTAssertNil(RemoteDesktopRegionPolicy.visibleRegion(picture: view, view: view, zoom: 1))
        XCTAssertNil(RemoteDesktopRegionPolicy.visibleRegion(picture: picture, view: view, zoom: 1.1))
        XCTAssertNil(RemoteDesktopRegionPolicy.visibleRegion(picture: picture.offsetBy(dx: 5000, dy: 0), view: view, zoom: 2))

        // Mac 主控端：放大时画面绕着指针走，指针底下那一点不动。
        let fit = CGRect(x: 0, y: 50, width: 900, height: 500)
        XCTAssertEqual(RemoteDesktopEventMapper.lensFrame(fit: fit, pointer: CGPoint(x: 450, y: 300), zoom: 1), fit)
        let centered = RemoteDesktopEventMapper.lensFrame(fit: fit, pointer: CGPoint(x: 450, y: 300), zoom: 2)
        XCTAssertEqual(centered, CGRect(x: -450, y: -200, width: 1800, height: 1000))
        // 指针在左上角：画面左上角对齐适配框；在右下角：右下角对齐。指针扫过整个窗口就看得到整块屏幕。
        XCTAssertEqual(RemoteDesktopEventMapper.lensFrame(fit: fit, pointer: fit.origin, zoom: 3).origin, fit.origin)
        let corner = RemoteDesktopEventMapper.lensFrame(fit: fit, pointer: CGPoint(x: fit.maxX, y: fit.maxY), zoom: 3)
        XCTAssertEqual(corner.maxX, fit.maxX, accuracy: 0.001)
        XCTAssertEqual(corner.maxY, fit.maxY, accuracy: 0.001)
        // 指针在黑边里：按最近的边算，画面不会跑出去。
        XCTAssertEqual(RemoteDesktopEventMapper.lensFrame(fit: fit, pointer: CGPoint(x: -40, y: 10), zoom: 3).origin, fit.origin)
        // 放大后看得见的那一块，正是要报给那台 Mac 的。
        let seen = try XCTUnwrap(RemoteDesktopRegionPolicy.visibleRegion(picture: centered, view: CGRect(x: 0, y: 0, width: 900, height: 600), zoom: 2))
        XCTAssertEqual(seen.x, 0.25, accuracy: 1e-9)
        XCTAssertEqual(seen.width, 0.5, accuracy: 1e-9)
        XCTAssertEqual(seen.y, 0.2, accuracy: 1e-9)
        XCTAssertEqual(seen.height, 0.6, accuracy: 1e-9)

        XCTAssertEqual(RemoteDesktopEventMapper.nextZoomStep(after: 1), 2)
        XCTAssertEqual(RemoteDesktopEventMapper.nextZoomStep(after: 2), 3)
        XCTAssertEqual(RemoteDesktopEventMapper.nextZoomStep(after: 3), 1)
        XCTAssertEqual(RemoteDesktopEventMapper.nextZoomStep(after: 1.7), 3, "捏合出来的中间值按下一档走")
    }

    // MARK: - 缩放器的裁切

    /// 四个象限四种颜色的 BGRA 图：左上红、右上绿、左下蓝、右下白。
    private func quadrants(width: Int, height: Int) -> CVPixelBuffer {
        var created: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &created)
        let image = created!
        CVPixelBufferLockBaseAddress(image, [])
        let stride = CVPixelBufferGetBytesPerRow(image)
        let base = CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let (b, g, r): (UInt8, UInt8, UInt8) = switch (x < width / 2, y < height / 2) {
                case (true, true): (0, 0, 255)
                case (false, true): (0, 255, 0)
                case (true, false): (255, 0, 0)
                case (false, false): (255, 255, 255)
                }
                let pixel = base + y * stride + x * 4
                pixel[0] = b; pixel[1] = g; pixel[2] = r; pixel[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(image, [])
        return image
    }

    /// 输出图亮度的最小 / 最大值（整张是一种颜色时两者很接近）。
    private func lumaRange(_ image: CVPixelBuffer) -> (min: Double, max: Double) {
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        let width = CVPixelBufferGetWidthOfPlane(image, 0), height = CVPixelBufferGetHeightOfPlane(image, 0)
        let luma = RemoteDesktopFixture.lumaReader(image)
        var low = 255.0, high = 0.0
        // 避开边缘两个像素：缩放滤波在边上会带进一点邻居。
        for y in stride(from: 2, to: height - 2, by: 3) {
            for x in stride(from: 2, to: width - 2, by: 3) {
                let value = luma(x, y)
                low = min(low, value); high = max(high, value)
            }
        }
        return (low, high)
    }

    func test_both_scalers_take_only_the_cropped_part() throws {
        let source = quadrants(width: 800, height: 400)
        let format = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let fast = try XCTUnwrap(RemoteFastFrameScaler(width: 400, height: 200, outputFormat: format))
        let fine = try XCTUnwrap(RemoteFrameScaler(width: 400, height: 200, outputFormat: format))
        // 整张：四种颜色都在，亮度跨度很大。
        let whole = try XCTUnwrap(fast.scale(source))
        XCTAssertGreaterThan(lumaRange(whole).max - lumaRange(whole).min, 100)

        // 每个象限单独裁出来（正好一比一）：整张输出是一种颜色。白最亮，蓝最暗，绿比红亮。
        let quadrant: [(name: String, rect: CGRect)] = [
            ("左上红", CGRect(x: 0, y: 0, width: 400, height: 200)), ("右上绿", CGRect(x: 400, y: 0, width: 400, height: 200)),
            ("左下蓝", CGRect(x: 0, y: 200, width: 400, height: 200)), ("右下白", CGRect(x: 400, y: 200, width: 400, height: 200)),
        ]
        for (label, scale) in [("快缩", { (crop: CGRect) in fast.scale(source, crop: crop) }),
                               ("Lanczos", { (crop: CGRect) in fine.scale(source, crop: crop) })] {
            var levels: [String: Double] = [:]
            for item in quadrant {
                let output = try XCTUnwrap(scale(item.rect), "\(label) 裁 \(item.name) 失败")
                let range = lumaRange(output)
                XCTAssertLessThan(range.max - range.min, 12, "\(label) 裁 \(item.name)：输出里混进了别的象限 \(range)")
                levels[item.name] = (range.min + range.max) / 2
            }
            XCTAssertGreaterThan(levels["右下白"]!, levels["右上绿"]! + 20, "\(label)：\(levels)")
            XCTAssertGreaterThan(levels["右上绿"]!, levels["左上红"]! + 20, "\(label)：\(levels)")
            XCTAssertGreaterThan(levels["左上红"]!, levels["左下蓝"]! + 10, "\(label)：\(levels)")
        }
        // 裁完再整张缩：裁切的标记没留在源图上。
        let again = try XCTUnwrap(fast.scale(source))
        XCTAssertGreaterThan(lumaRange(again).max - lumaRange(again).min, 100)
    }

    func test_region_tag_round_trips_and_clears() {
        let image = RemoteDesktopFixture.makeFrame(width: 64, height: 64, seed: 1)
        XCTAssertNil(RemoteFrameRegionTag.region(of: image))
        let region = RemoteDesktopRegion(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        RemoteFrameRegionTag.set(region, on: image)
        XCTAssertEqual(RemoteFrameRegionTag.region(of: image), region)
        RemoteFrameRegionTag.set(nil, on: image)
        XCTAssertNil(RemoteFrameRegionTag.region(of: image), "池里的缓冲轮着用：整块的帧要把标记摘掉")
    }

    // MARK: - 帧头

    func test_frame_header_carries_region_and_stays_the_same_without_it() throws {
        XCTAssertEqual(RemoteMessage.Kind.desktopRegion.rawValue, 57)
        XCTAssertEqual(RemoteFeature.desktopRegion, "desktop-region")
        let plain = RemoteDesktopFrame(flags: [.keyframe], codec: .hevc, sequence: 7, captureNanos: 99, width: 1856, height: 1206,
                                       parameterSets: [Data([1, 2])], data: Data([9, 8, 7]))
        XCTAssertFalse(plain.flags.contains(.hasRegion))
        XCTAssertEqual(plain.encoded().count, RemoteDesktopFrame.headerSize + 1 + 2 + 2 + 3, "不带区域时线格式一个字节都不变")
        XCTAssertNil(try RemoteDesktopFrame(decoding: plain.encoded()).region)

        let region = RemoteDesktopRegion(x: 0.25, y: 0.5, width: 0.125, height: 0.375)
        let regional = RemoteDesktopFrame(flags: [], codec: .hevc, sequence: 8, captureNanos: 100, width: 1856, height: 1206,
                                          parameterSets: [], data: Data([1]), ltrToken: 42, region: region)
        XCTAssertTrue(regional.flags.contains(.hasRegion))
        XCTAssertEqual(regional.encoded().count, RemoteDesktopFrame.headerSize + 8 + 8 + 1)
        let decoded = try RemoteDesktopFrame(decoding: regional.encoded())
        XCTAssertEqual(decoded.ltrToken, 42)
        XCTAssertEqual(decoded.data, Data([1]))
        let back = try XCTUnwrap(decoded.region)
        XCTAssertEqual(back.x, 0.25, accuracy: 1.0 / 65535)
        XCTAssertEqual(back.y, 0.5, accuracy: 1.0 / 65535)
        XCTAssertEqual(back.width, 0.125, accuracy: 1.0 / 65535)
        XCTAssertEqual(back.height, 0.375, accuracy: 1.0 / 65535)
    }

    // MARK: - 端到端

    func test_region_request_reaches_the_source_and_frames_come_back_tagged() async throws {
        let (server, mac, client) = try await makeRig()
        defer { server.stop() }
        XCTAssertTrue(client.supportsDesktopRegion)
        let session = RemoteDesktopSession(client: client, maxWidth: 1206, maxHeight: 2622)
        defer { session.stop() }
        let regions = RegionLog()
        session.receiver.setHandlers(onImage: { _, frame in regions.add(frame.region) }, onCursor: { _ in })

        // 开流前就放大着：流一开就补发。
        let visible = RemoteDesktopRegion(x: 0.375, y: 0.375, width: 0.25, height: 0.25)
        session.requestRegion(visible)
        await session.start()
        XCTAssertEqual(session.state, .streaming)
        let source = try XCTUnwrap(mac.latestSource)
        let arrived = await waitUntil { source.requestedRegions.last == visible }
        XCTAssertTrue(arrived, "开流后应把想要的那一块补发给 Mac：\(source.requestedRegions)")

        // 来源按区域出帧：主控端收到的帧带着那一块；回到整块后不带。
        let first = await waitUntil { regions.count >= 1 }
        XCTAssertTrue(first)
        XCTAssertNil(regions.last ?? nil, "整块的帧不带区域")
        let taken = RemoteDesktopRegion(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        source.emittedRegion = taken
        source.emit()
        let tagged = await waitUntil { (regions.last ?? nil) != nil }
        XCTAssertTrue(tagged, "按区域出的帧应带着区域")
        let got = try XCTUnwrap(regions.last ?? nil)
        XCTAssertEqual(got.x, 0.25, accuracy: 1.0 / 65535)
        XCTAssertEqual(got.width, 0.5, accuracy: 1.0 / 65535)

        // 同一块不重发；换一块、缩回去各发一次。
        let before = source.requestedRegions.count
        session.requestRegion(visible)
        session.requestRegion(RemoteDesktopRegion(x: 0.5, y: 0.5, width: 0.25, height: 0.25))
        session.requestRegion(nil)
        let done = await waitUntil { source.requestedRegions.count == before + 2 }
        XCTAssertTrue(done, "\(source.requestedRegions)")
        XCTAssertNil(source.requestedRegions.last ?? RemoteDesktopRegion.whole)
        source.emittedRegion = nil
        source.emit()
        let plain = await waitUntil { (regions.last ?? nil) == nil }
        XCTAssertTrue(plain)
    }

    func test_old_mac_gets_no_region_request() async throws {
        let old = RemoteConstants.localFeatures.filter { $0 != RemoteFeature.desktopRegion }
        let (server, mac, client) = try await makeRig(features: old)
        defer { server.stop() }
        XCTAssertFalse(client.supportsDesktopRegion)
        let session = RemoteDesktopSession(client: client, maxWidth: 1206, maxHeight: 2622)
        defer { session.stop() }
        await session.start()
        XCTAssertEqual(session.state, .streaming)
        session.requestRegion(RemoteDesktopRegion(x: 0.375, y: 0.375, width: 0.25, height: 0.25))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(client.state, .connected, "老 Mac 收到不认识的消息会断开：不能发")
        XCTAssertEqual(mac.latestSource?.requestedRegions.count, 0)
    }

    // MARK: - 夹具

    private final class RegionLog: @unchecked Sendable {
        private let lock = NSLock()
        private var regions: [RemoteDesktopRegion?] = []
        func add(_ region: RemoteDesktopRegion?) { lock.lock(); regions.append(region); lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return regions.count }
        var last: RemoteDesktopRegion?? { lock.lock(); defer { lock.unlock() }; return regions.last }
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(3))
        }
        return true
    }

    private func makeRig(features: [String] = RemoteConstants.localFeatures)
        async throws -> (RemoteHostServer, FakeDesktopMac, RemoteMacClient) {
        let mac = FakeDesktopMac()
        let server = RemoteHostServer(registry: TerminalSessionRegistry(),
                                      identity: RemoteIdentityStore(role: .controllers, storage: RemoteMemoryStorage()),
                                      localName: "测试 Mac", localID: UUID(), advertises: false,
                                      localFeatures: features, desktopEnvironment: mac.environment())
        server.start()
        let ready = await waitUntil { server.port != nil }
        XCTAssertTrue(ready, "服务端没起来：\(server.status)")
        let phoneIdentity = RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage())
        try server.trust(RemotePeer(id: RemoteLocalDevice.id(), name: "测试 iPhone",
                                    publicKey: try phoneIdentity.localIdentity().publicKey.rawRepresentation,
                                    pairedAt: Date()))
        let client = RemoteMacClient(macName: "测试 Mac",
                                     endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: try XCTUnwrap(server.port))!),
                                     identity: phoneIdentity)
        await client.connect()
        XCTAssertEqual(client.state, .connected)
        return (server, mac, client)
    }
}
