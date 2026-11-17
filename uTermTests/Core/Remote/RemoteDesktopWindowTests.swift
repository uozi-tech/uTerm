import CoreGraphics
import CoreVideo
import XCTest
@preconcurrency import Network
@testable import uTerm

/// 远程桌面「只看一个窗口」：窗口列表、按窗口开流、画面范围变了之后的几何更新。
///
/// 采集换成合成画面（测试进程没有屏幕录制授权），其余是生产代码：真服务端、真连接、真客户端与会话。
@MainActor
final class RemoteDesktopWindowTests: XCTestCase {
    // MARK: - 端到端

    func test_lists_windows_then_streams_one_and_follows_its_geometry() async throws {
        let (server, mac, client) = try await makeRig()
        defer { server.stop() }
        mac.windows = [(id: 42, app: "Xcode", title: "uTerm — RemoteProtocol.swift", bounds: CGRect(x: 200, y: 100, width: 951, height: 639)),
                       (id: 43, app: "Google Chrome", title: "", bounds: CGRect(x: 0, y: 30, width: 1200, height: 800))]
        XCTAssertTrue(client.supportsDesktopWindows, "新版 Mac 握手时报 desktop-windows 能力")

        // 1. 列表原样到达，顺序不变。
        let list = try await client.desktopWindows()
        XCTAssertNil(list.message)
        XCTAssertEqual(list.windows.map(\.id), [42, 43])
        XCTAssertEqual(list.windows[0].menuTitle, "uTerm — RemoteProtocol.swift")
        XCTAssertEqual(list.windows[0].menuDetail, "Xcode · 951×639")
        XCTAssertEqual(list.windows[1].menuTitle, "Google Chrome", "没标题的窗口用 App 名")
        XCTAssertEqual(list.windows[1].menuDetail, "1200×800")

        // 2. 先看整块显示器，再换成只看 42 号窗口：重开流，Mac 先把它提到最前，采集目标是那个窗口。
        let session = RemoteDesktopSession(client: client, maxWidth: 2007, maxHeight: 2853)
        defer { session.stop() }
        await session.start()
        XCTAssertEqual(session.state, .streaming)
        XCTAssertNil(session.info?.windowID)
        XCTAssertEqual(mac.openedWindows, [nil])
        XCTAssertEqual(mac.latestSource?.observesGeometry, false, "整块显示器的流不订几何")

        await session.switchWindow(to: 42)
        XCTAssertEqual(session.state, .streaming)
        let info = try XCTUnwrap(session.info)
        XCTAssertEqual(info.windowID, 42)
        XCTAssertEqual(info.windowTitle, "uTerm — RemoteProtocol.swift")
        XCTAssertEqual(info.displayWidth, 951, "归一化坐标与画面比例按窗口的点尺寸算")
        XCTAssertEqual(info.displayHeight, 639)
        // 窗口 1902×1278 像素，比手机要的框小：不放大，原样。
        XCTAssertEqual(info.streamWidth, 1902)
        XCTAssertEqual(info.streamHeight, 1278)
        XCTAssertEqual(mac.raisedWindows, [42])
        XCTAssertEqual(mac.openedWindows, [nil, 42])
        XCTAssertEqual(session.contentFraction, CGSize(width: 1, height: 1))
        let source = try XCTUnwrap(mac.latestSource)
        XCTAssertTrue(source.observesGeometry)

        // 3. 光挪位置：注入与光标回报按新位置算，主控端不用知道（尺寸和占比都没变）。
        source.report(.whole(CGRect(x: 500, y: 300, width: 951, height: 639)))
        let moved = await waitUntil { mac.injector.allBounds.last == CGRect(x: 500, y: 300, width: 951, height: 639) }
        XCTAssertTrue(moved, "窗口挪了，注入的范围要跟着走")
        XCTAssertEqual(session.info?.displayWidth, 951)

        // 4. 窗口变大（或菜单伸出窗口）：系统把新范围缩进同一帧，下边空出一截。主控端收到新的点尺寸与占比。
        let grown = RemoteDesktopFrameGeometry(bounds: CGRect(x: 500, y: 300, width: 1200, height: 700),
                                               contentFraction: CGSize(width: 1, height: 0.868))
        source.report(grown)
        let updated = await waitUntil { session.info?.displayWidth == 1200 }
        XCTAssertTrue(updated, "几何更新没到主控端")
        XCTAssertEqual(session.info?.displayHeight, 700)
        XCTAssertEqual(session.contentFraction.width, 1, accuracy: 0.0001)
        XCTAssertEqual(session.contentFraction.height, 0.868, accuracy: 0.0001)
        XCTAssertEqual(mac.injector.allBounds.last, grown.bounds)

        // 5. 再重开一条流（换回整块显示器）：占比回到 1，不带着上一条流的裁切。
        await session.switchWindow(to: nil)
        XCTAssertEqual(session.state, .streaming)
        XCTAssertNil(session.info?.windowID)
        XCTAssertEqual(session.contentFraction, CGSize(width: 1, height: 1))
        XCTAssertEqual(session.info?.displayWidth, 1512)
        XCTAssertEqual(mac.openedWindows, [nil, 42, nil])
    }

    func test_fits_window_to_viewer_canvas_and_restores_it_afterwards() async throws {
        let (server, mac, client) = try await makeRig()
        defer { server.stop() }
        let original = CGRect(x: 200, y: 100, width: 1512, height: 874)
        mac.windows = [(id: 42, app: "Xcode", title: "A", bounds: original),
                       (id: 43, app: "Google Chrome", title: "B", bounds: CGRect(x: 0, y: 30, width: 1200, height: 800))]
        let session = RemoteDesktopSession(client: client, maxWidth: 2007, maxHeight: 2853)
        defer { session.stop() }

        // 1. 按手机画布（Duo 内屏横握，扣掉顶栏）开：Mac 先把窗口调成这么大，流按调好的尺寸来。
        await session.switchWindow(to: 42, fit: CGSize(width: 951, height: 619))
        XCTAssertEqual(session.state, .streaming)
        XCTAssertEqual(mac.fittedWindows.map(\.id), [42])
        XCTAssertEqual(mac.fittedWindows.last?.size, CGSize(width: 951, height: 619))
        XCTAssertEqual(session.info?.displayWidth, 951)
        XCTAssertEqual(session.info?.displayHeight, 619)
        XCTAssertEqual(session.info?.streamWidth, 1902, "窗口 2 倍像素没超过手机要的框：原样，不缩")
        XCTAssertTrue(mac.restoredWindows.isEmpty)

        // 2. 转屏：画布变了，按新的再调一次；中间窗口先回到原位，最初的位置没丢。
        await session.refitWindow(to: CGSize(width: 669, height: 901))
        XCTAssertEqual(session.state, .streaming)
        XCTAssertEqual(mac.fittedWindows.last?.size, CGSize(width: 669, height: 901))
        XCTAssertEqual(session.info?.displayWidth, 669)
        XCTAssertEqual(session.info?.displayHeight, 901)
        // 差不到 8 点不重调（键盘条收放之类的抖动）。
        let fitsBefore = mac.fittedWindows.count
        await session.refitWindow(to: CGSize(width: 672, height: 905))
        XCTAssertEqual(mac.fittedWindows.count, fitsBefore)

        // 3. 换去看另一个窗口：先前那个放回最初的位置和大小。
        await session.switchWindow(to: 43)
        XCTAssertEqual(session.state, .streaming)
        let restored = await waitUntil { mac.windows.first { $0.id == 42 }?.bounds == original }
        XCTAssertTrue(restored, "换窗口后先前调过大小的窗口应还原：\(mac.restoredWindows)")
        XCTAssertEqual(mac.fittedWindows.count, fitsBefore, "没带 fit 的不调大小")

        // 4. 要的比 App 的最小窗口还小：得到的是最小尺寸，流照开。
        await session.switchWindow(to: 43, fit: CGSize(width: 300, height: 200))
        XCTAssertEqual(session.state, .streaming)
        XCTAssertEqual(session.info?.displayWidth, 400)
        XCTAssertEqual(session.info?.displayHeight, 350)

        // 5. 关掉屏幕：窗口放回去。
        session.stop()
        let back = await waitUntil { mac.windows.first { $0.id == 43 }?.bounds == CGRect(x: 0, y: 30, width: 1200, height: 800) }
        XCTAssertTrue(back, "停流后窗口应还原：\(mac.restoredWindows)")
    }

    func test_connection_drop_restores_fitted_window() async throws {
        let (server, mac, client) = try await makeRig()
        defer { server.stop() }
        let original = CGRect(x: 200, y: 100, width: 1512, height: 874)
        mac.windows = [(id: 42, app: "Xcode", title: "A", bounds: original)]
        let session = RemoteDesktopSession(client: client, maxWidth: 2007, maxHeight: 2853)
        await session.switchWindow(to: 42, fit: CGSize(width: 951, height: 619))
        XCTAssertEqual(session.state, .streaming)
        XCTAssertEqual(mac.windows[0].bounds.size, CGSize(width: 951, height: 619))
        // 手机那头整条连接断了（没来得及发停流）：Mac 自己把窗口放回去。
        client.disconnect()
        let restored = await waitUntil { mac.windows[0].bounds == original }
        XCTAssertTrue(restored, "连接断开后窗口应还原")
    }

    func test_view_only_does_not_resize_the_window() async throws {
        let (server, mac, client) = try await makeRig()
        defer { server.stop() }
        mac.windows = [(id: 42, app: "Xcode", title: "A", bounds: CGRect(x: 0, y: 0, width: 1512, height: 874))]
        mac.canControl = false
        let session = RemoteDesktopSession(client: client, maxWidth: 2007, maxHeight: 2853)
        defer { session.stop() }
        await session.switchWindow(to: 42, fit: CGSize(width: 951, height: 619))
        XCTAssertEqual(session.state, .streaming)
        XCTAssertTrue(mac.fittedWindows.isEmpty, "没有辅助功能授权时不动窗口")
        XCTAssertEqual(session.info?.displayWidth, 1512)
    }

    func test_window_gone_is_rejected_and_connection_survives() async throws {
        let (server, mac, client) = try await makeRig()
        defer { server.stop() }
        let session = RemoteDesktopSession(client: client, maxWidth: 2007, maxHeight: 2853)
        defer { session.stop() }
        await session.switchWindow(to: 99)
        guard case .failed(let message) = session.state else { return XCTFail("窗口不存在应被拒：\(session.state)") }
        XCTAssertTrue(message.contains("找不到要看的窗口"), message)
        XCTAssertEqual(client.state, .connected)
        XCTAssertTrue(mac.sources.isEmpty, "被拒时不该开采集")
    }

    func test_view_only_does_not_raise_the_window() async throws {
        let (server, mac, client) = try await makeRig()
        defer { server.stop() }
        mac.windows = [(id: 42, app: "Xcode", title: "A", bounds: CGRect(x: 0, y: 0, width: 800, height: 600))]
        // 没有「辅助功能」授权：提不动窗口（同一项授权），流照开。
        mac.canControl = false
        let session = RemoteDesktopSession(client: client, maxWidth: 2007, maxHeight: 2853)
        defer { session.stop() }
        await session.switchWindow(to: 42)
        XCTAssertEqual(session.state, .streaming)
        XCTAssertEqual(session.info?.windowID, 42)
        XCTAssertTrue(mac.raisedWindows.isEmpty)
    }

    func test_window_list_explains_when_desktop_is_off_or_unauthorized() async throws {
        let (server, mac, client) = try await makeRig()
        defer { server.stop() }
        mac.windows = [(id: 42, app: "Xcode", title: "A", bounds: CGRect(x: 0, y: 0, width: 800, height: 600))]
        mac.enabled = false
        var list = try await client.desktopWindows()
        XCTAssertTrue(list.windows.isEmpty)
        XCTAssertTrue(list.message?.contains("没有打开远程桌面") == true, list.message ?? "nil")
        mac.enabled = true
        mac.screenAuthorized = false
        list = try await client.desktopWindows()
        XCTAssertTrue(list.windows.isEmpty)
        XCTAssertTrue(list.message?.contains("屏幕录制") == true, list.message ?? "nil")
    }

    func test_old_mac_gets_no_window_request() async throws {
        // 老 Mac：不声明 desktop-windows。主控端不发 `desktopWindows`（老 Mac 会断开整条连接），开流也不带窗口号。
        let old = RemoteConstants.localFeatures.filter { $0 != RemoteFeature.desktopWindows }
        let (server, mac, client) = try await makeRig(features: old)
        defer { server.stop() }
        mac.windows = [(id: 42, app: "Xcode", title: "A", bounds: CGRect(x: 0, y: 0, width: 800, height: 600))]
        XCTAssertFalse(client.supportsDesktopWindows)
        do {
            _ = try await client.desktopWindows()
            XCTFail("老 Mac 上应直接报版本太旧")
        } catch RemoteAttachError.rejected(let message) {
            XCTAssertTrue(message.contains("版本太旧"), message)
        }
        XCTAssertEqual(client.state, .connected)
        let session = RemoteDesktopSession(client: client, maxWidth: 2007, maxHeight: 2853)
        defer { session.stop() }
        XCTAssertFalse(session.supportsWindows)
        await session.switchWindow(to: 42)
        XCTAssertEqual(session.state, .streaming)
        XCTAssertEqual(mac.openedWindows, [nil], "老 Mac 上照旧看整块显示器")
        XCTAssertTrue(mac.raisedWindows.isEmpty)
    }

    // MARK: - 几何换算

    func test_frame_geometry_from_capture_attachments() throws {
        // 2026-11-17 探针的读数：400×332 的窗口按 800×664 开流，之后放大到 520×412。
        let start = try XCTUnwrap(RemoteDesktopFrameGeometry.make(
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 332), contentScale: 1, scaleFactor: 2,
            screenRect: CGRect(x: 300, y: 664, width: 400, height: 332), frameSize: CGSize(width: 800, height: 664)))
        XCTAssertEqual(start, .whole(CGRect(x: 300, y: 664, width: 400, height: 332)))

        let grown = try XCTUnwrap(RemoteDesktopFrameGeometry.make(
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 316), contentScale: 0.7692307829856873, scaleFactor: 2,
            screenRect: CGRect(x: 300, y: 664, width: 520, height: 412), frameSize: CGSize(width: 800, height: 664)))
        XCTAssertEqual(grown.bounds.origin, CGPoint(x: 300, y: 664))
        XCTAssertEqual(grown.bounds.width, 520, accuracy: 0.5)
        XCTAssertEqual(grown.bounds.height, 411, accuracy: 1)
        XCTAssertEqual(grown.contentFraction.width, 1, accuracy: 0.001)
        XCTAssertEqual(grown.contentFraction.height, 632.0 / 664, accuracy: 0.001)
        XCTAssertTrue(grown.differsVisibly(from: start))

        // 菜单伸出窗口：范围比窗口大，系统报的屏幕位置还是窗口的。按左上角不动算。
        let menu = try XCTUnwrap(RemoteDesktopFrameGeometry.make(
            contentRect: CGRect(x: 0, y: 0, width: 399, height: 326), contentScale: 0.681430995464325, scaleFactor: 2,
            screenRect: CGRect(x: 450, y: 524, width: 520, height: 412), frameSize: CGSize(width: 800, height: 664)))
        XCTAssertEqual(menu.bounds.origin, CGPoint(x: 450, y: 524))
        XCTAssertEqual(menu.bounds.width, 585.5, accuracy: 0.5)
        XCTAssertEqual(menu.bounds.height, 478.4, accuracy: 0.5)

        // 光挪位置不算「看得出的变化」。
        let moved = RemoteDesktopFrameGeometry.whole(CGRect(x: 900, y: 10, width: 400, height: 332))
        XCTAssertFalse(moved.differsVisibly(from: start))

        // 缺东西、尺寸为零都算不出。
        XCTAssertNil(RemoteDesktopFrameGeometry.make(contentRect: .zero, contentScale: 1, scaleFactor: 2,
                                                     screenRect: .zero, frameSize: CGSize(width: 800, height: 664)))
        XCTAssertNil(RemoteDesktopFrameGeometry.make(contentRect: CGRect(x: 0, y: 0, width: 10, height: 10), contentScale: 0,
                                                     scaleFactor: 2, screenRect: .zero, frameSize: CGSize(width: 800, height: 664)))
    }

    func test_window_fit_shrinks_the_window_for_bigger_text() {
        let canvas = CGSize(width: 951, height: 619)
        XCTAssertEqual(RemoteDesktopWindowFit.size(canvas: canvas, textScale: 1), CGSize(width: 951, height: 619))
        // 字大 1.25 倍：窗口只有画布的 0.8，画面放大 1.25 倍铺满。
        XCTAssertEqual(RemoteDesktopWindowFit.size(canvas: canvas, textScale: 1.25), CGSize(width: 761, height: 495))
        XCTAssertEqual(RemoteDesktopWindowFit.size(canvas: canvas, textScale: 0.8), CGSize(width: 1189, height: 774))
        // 离谱的值夹住；画布还没量出来时没有尺寸。
        XCTAssertEqual(RemoteDesktopWindowFit.size(canvas: canvas, textScale: 10), CGSize(width: 476, height: 310))
        XCTAssertNil(RemoteDesktopWindowFit.size(canvas: .zero, textScale: 1))
        XCTAssertNil(RemoteDesktopWindowFit.size(canvas: canvas, textScale: .nan))
        XCTAssertTrue(RemoteDesktopWindowFit.textScales.contains(1))
    }

    func test_listable_windows_skip_overlays_and_tiny_ones() {
        func entry(_ id: UInt32, layer: Int = 0, alpha: Double = 1, size: CGSize = CGSize(width: 800, height: 600),
                   app: String = "App", title: String = "") -> RemoteDesktopWindows.Entry {
            RemoteDesktopWindows.Entry(id: id, pid: 100, app: app, title: title,
                                       bounds: CGRect(origin: .zero, size: size), layer: layer, alpha: alpha)
        }
        let listed = RemoteDesktopWindows.listable([
            entry(1, app: "Xcode", title: "uTerm"),
            entry(2, layer: 25),                                   // 菜单栏上的状态项
            entry(3, alpha: 0),                                    // 看不见的
            entry(4, size: CGSize(width: 120, height: 40)),        // 太小
            entry(5, app: "Google Chrome"),
        ])
        XCTAssertEqual(listed.map(\.id), [1, 5], "只留普通层级、看得见、不太小的，顺序不变")
        XCTAssertEqual(listed[0], RemoteDesktopWindowSummary(id: 1, app: "Xcode", title: "uTerm", width: 800, height: 600))
    }

    func test_window_frame_matching_tolerates_one_point() {
        let frame = CGRect(x: 100, y: 50, width: 800, height: 600)
        XCTAssertTrue(RemoteDesktopWindows.matches(frame, frame.offsetBy(dx: 0.5, dy: -1)))
        XCTAssertFalse(RemoteDesktopWindows.matches(frame, frame.offsetBy(dx: 2, dy: 0)))
        XCTAssertFalse(RemoteDesktopWindows.matches(frame, CGRect(x: 100, y: 50, width: 803, height: 600)))
    }

    // MARK: - 重复帧比对

    func test_identical_frames_compare_equal_and_one_changed_byte_does_not() {
        let first = RemoteDesktopFixture.makeFrame(width: 320, height: 200, seed: 3)
        let same = RemoteDesktopFixture.makeFrame(width: 320, height: 200, seed: 3)
        let other = RemoteDesktopFixture.makeFrame(width: 320, height: 200, seed: 4)
        XCTAssertTrue(RemoteFrameCompare.identical(first, first))
        XCTAssertTrue(RemoteFrameCompare.identical(first, same))
        XCTAssertFalse(RemoteFrameCompare.identical(first, other))
        XCTAssertFalse(RemoteFrameCompare.identical(first, RemoteDesktopFixture.makeFrame(width: 320, height: 202, seed: 3)),
                       "尺寸不同不算一样")

        // 只改色度面最后一行的最后一个字节（闪烁的光标就是这么小的变化）：必须比得出来。
        CVPixelBufferLockBaseAddress(same, [])
        let stride = CVPixelBufferGetBytesPerRowOfPlane(same, 1)
        let rows = CVPixelBufferGetHeightOfPlane(same, 1)
        let chroma = CVPixelBufferGetBaseAddressOfPlane(same, 1)!.assumingMemoryBound(to: UInt8.self)
        chroma[(rows - 1) * stride + 319] ^= 0xFF
        CVPixelBufferUnlockBaseAddress(same, [])
        XCTAssertFalse(RemoteFrameCompare.identical(first, same))
    }

    // MARK: - 协议

    func test_wire_numbers_and_old_peers_ignore_the_new_keys() throws {
        XCTAssertEqual(RemoteMessage.Kind.desktopWindows.rawValue, 54)
        XCTAssertEqual(RemoteMessage.Kind.desktopWindowList.rawValue, 55)
        XCTAssertEqual(RemoteMessage.Kind.desktopGeometry.rawValue, 56)
        XCTAssertEqual(RemoteFeature.desktopWindows, "desktop-windows")
        XCTAssertTrue(RemoteConstants.localFeatures.contains(RemoteFeature.desktopWindows))

        // 老主控端的开流请求没有 windowID：解出来是 nil（整块显示器）。
        let legacy = #"{"requestID":"8E6B6C7E-2D6B-4B0B-9A52-3F4E2A1B0C9D","maxWidth":1206,"maxHeight":2622,"codec":"hevc"}"#
        let request = try RemoteJSON.decode(RemoteDesktopStartRequest.self, from: Data(legacy.utf8))
        XCTAssertNil(request.windowID)

        var withWindow = request
        withWindow.windowID = 42
        XCTAssertEqual(try RemoteJSON.decode(RemoteDesktopStartRequest.self, from: RemoteJSON.encode(withWindow)).windowID, 42)

        let update = RemoteDesktopGeometryUpdate(width: 1200, height: 700, contentWidth: 1, contentHeight: 0.868)
        XCTAssertEqual(try RemoteJSON.decode(RemoteDesktopGeometryUpdate.self, from: RemoteJSON.encode(update)), update)
    }

    // MARK: - 夹具

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(3))
        }
        return true
    }

    /// 服务端（不广播，只在 127.0.0.1 监听）+ 已预先互信、已连上的手机客户端。
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
