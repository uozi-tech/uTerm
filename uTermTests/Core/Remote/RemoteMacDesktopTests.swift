import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@preconcurrency import Network
@testable import uTerm

/// Mac 控 Mac 的屏幕标签：本机键鼠 → 远程输入的换算、本机剪贴板 → 粘贴内容，以及画布对着真实的
/// `RemoteHostServer`（合成采集 + 记录注入）端到端发出的输入。
@MainActor
final class RemoteMacDesktopTests: XCTestCase {

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    // MARK: - 换算

    func test_modifier_flags_map_to_remote_modifiers() {
        XCTAssertEqual(RemoteDesktopEventMapper.modifiers([.command, .shift]), [.command, .shift])
        XCTAssertEqual(RemoteDesktopEventMapper.modifiers([.option, .control, .capsLock, .function]),
                       [.option, .control, .capsLock, .function])
        XCTAssertEqual(RemoteDesktopEventMapper.modifiers([.numericPad]), [], "小键盘位不是修饰键")
    }

    func test_scroll_passes_precise_deltas_and_scales_wheel_lines() {
        XCTAssertEqual(RemoteDesktopEventMapper.scroll(dx: 1.5, dy: -12, precise: true, phase: .changed, momentumPhase: []),
                       .scroll(dx: 1.5, dy: -12, phase: .changed))
        XCTAssertEqual(RemoteDesktopEventMapper.scroll(dx: 0, dy: 2, precise: false, phase: [], momentumPhase: []),
                       .scroll(dx: 0, dy: 20, phase: .none), "滚轮一行按 10 像素")
        XCTAssertNil(RemoteDesktopEventMapper.scroll(dx: 0, dy: 0, precise: true, phase: .mayBegin, momentumPhase: []),
                     "手指刚碰到触控板不发")
    }

    func test_scroll_phases_follow_gesture_then_momentum() {
        func phase(_ p: NSEvent.Phase, _ m: NSEvent.Phase) -> RemoteScrollPhase? {
            RemoteDesktopEventMapper.scrollPhase(phase: p, momentumPhase: m)
        }
        XCTAssertEqual(phase(.began, []), .began)
        XCTAssertEqual(phase(.changed, []), .changed)
        XCTAssertEqual(phase(.ended, []), .ended)
        XCTAssertEqual(phase(.cancelled, []), .ended)
        XCTAssertEqual(phase([], .began), .momentumBegan)
        XCTAssertEqual(phase([], .changed), .momentum)
        XCTAssertEqual(phase([], .ended), .momentumEnded)
        XCTAssertEqual(phase([], []), RemoteScrollPhase.none)
    }

    func test_flags_changed_becomes_modifier_key_down_and_up() {
        XCTAssertEqual(RemoteDesktopEventMapper.modifierKey(code: 0x38, flags: [.shift]),
                       [.key(code: 0x38, down: true, modifiers: [.shift])])
        XCTAssertEqual(RemoteDesktopEventMapper.modifierKey(code: 0x38, flags: []),
                       [.key(code: 0x38, down: false, modifiers: [])])
        XCTAssertEqual(RemoteDesktopEventMapper.modifierKey(code: 0x36, flags: [.command]),
                       [.key(code: 0x36, down: true, modifiers: [.command])], "右 ⌘")
        XCTAssertEqual(RemoteDesktopEventMapper.modifierKey(code: 0x39, flags: [.capsLock]),
                       [.key(code: 0x39, down: true, modifiers: [.capsLock]),
                        .key(code: 0x39, down: false, modifiers: [.capsLock])], "大写锁定每次完整按一下")
        XCTAssertEqual(RemoteDesktopEventMapper.modifierKey(code: 0x00, flags: [.shift]), [], "不是修饰键")
    }

    func test_only_plain_command_v_is_taken_over_as_paste() {
        XCTAssertTrue(RemoteDesktopEventMapper.isPasteShortcut(code: 0x09, flags: [.command]))
        XCTAssertTrue(RemoteDesktopEventMapper.isPasteShortcut(code: 0x09, flags: [.command, .capsLock]))
        XCTAssertFalse(RemoteDesktopEventMapper.isPasteShortcut(code: 0x09, flags: [.command, .shift, .option]),
                       "⌥⇧⌘V（粘贴并匹配样式）照常发过去")
        XCTAssertFalse(RemoteDesktopEventMapper.isPasteShortcut(code: 0x08, flags: [.command]))
        XCTAssertFalse(RemoteDesktopEventMapper.isPasteShortcut(code: 0x09, flags: []))
    }

    func test_pointer_on_letterbox_sticks_to_the_nearest_display_edge() {
        // 2:1 的屏幕放进 1000×600：上下各留 50 点黑边。
        let viewport = RemoteDesktopViewport(contentSize: CGSize(width: 2000, height: 1000),
                                             viewSize: CGSize(width: 1000, height: 600))
        let center = RemoteDesktopEventMapper.normalized(CGPoint(x: 500, y: 300), in: viewport)
        XCTAssertEqual(center.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(center.y, 0.5, accuracy: 0.0001)
        let top = RemoteDesktopEventMapper.normalized(CGPoint(x: 250, y: 10), in: viewport)
        XCTAssertEqual(top.x, 0.25, accuracy: 0.0001)
        XCTAssertEqual(top.y, 0)
        XCTAssertFalse(RemoteDesktopEventMapper.isOnDisplay(CGPoint(x: 250, y: 10), in: viewport))
        XCTAssertTrue(RemoteDesktopEventMapper.isOnDisplay(CGPoint(x: 250, y: 60), in: viewport))
    }

    func test_window_is_resized_so_the_picture_has_no_letterbox() {
        // 窗口 1280×840，顶栏 38：画布 1280×802。那台是 16:9 → 画布要 1280×720，窗口高 758，上沿不动。
        let window = CGRect(x: 100, y: 100, width: 1280, height: 840)
        let visible = CGRect(x: 0, y: 0, width: 1512, height: 945)
        let fitted = RemoteDesktopCanvasNSView.fittedFrame(window: window, canvas: CGSize(width: 1280, height: 802),
                                                           display: CGSize(width: 1920, height: 1080), visible: visible)
        XCTAssertEqual(fitted, CGRect(x: 100, y: 182, width: 1280, height: 758))
        // 竖屏的那台：按可见区高度封顶，宽度等比缩。
        let tall = RemoteDesktopCanvasNSView.fittedFrame(window: window, canvas: CGSize(width: 1280, height: 802),
                                                         display: CGSize(width: 1080, height: 1920), visible: visible)
        XCTAssertEqual(tall.maxY, window.maxY, "上沿不动")
        XCTAssertEqual(tall.minY, visible.minY)
        XCTAssertEqual(tall.height - 38, (tall.width * 1920 / 1080).rounded(), accuracy: 1)
    }

    func test_shortcut_capture_only_while_this_window_has_the_keyboard() {
        func should(_ enabled: Bool = true, app: Bool = true, key: Bool = true, focused: Bool = true,
                    control: Bool = true) -> Bool {
            RemoteDesktopKeyboardCapture.shouldCapture(enabled: enabled, appActive: app, windowKey: key,
                                                       canvasFocused: focused, canControl: control)
        }
        XCTAssertTrue(should())
        XCTAssertFalse(should(false), "开关关着")
        XCTAssertFalse(should(app: false), "切到别的 app：立刻放开整台机器的键盘")
        XCTAssertFalse(should(key: false), "切到本 app 的别的窗口")
        XCTAssertFalse(should(focused: false), "焦点在输入框（如锁屏密码）上")
        XCTAssertFalse(should(control: false), "只能查看")
    }

    func test_switching_to_another_display_reopens_the_stream_on_it() async throws {
        let rig = try await makeRig()
        defer { rig.client.disconnect() }
        rig.mac.hasSecondDisplay = true
        let session = RemoteDesktopSession(client: rig.client, maxWidth: 1920, maxHeight: 1080)
        defer { session.stop() }
        await session.start()
        let first = try XCTUnwrap(session.info)
        XCTAssertEqual(first.displayID, 7, "不指定就看主显示器")
        XCTAssertEqual(first.displays?.map(\.id), [7, 9])
        XCTAssertEqual(first.displays?.first?.isMain, true)
        await session.switchDisplay(to: 9)
        XCTAssertEqual(session.state, .streaming)
        let second = try XCTUnwrap(session.info)
        XCTAssertEqual(second.displayID, 9)
        XCTAssertEqual(second.displayWidth, 1920)
        XCTAssertEqual(rig.mac.openedDisplays, [7, 9])
        XCTAssertEqual(rig.mac.preparedDisplays, 2, "每次开流前先整理显示器（无显示器换 2 倍）")
        await session.switchDisplay(to: 9)
        XCTAssertEqual(rig.mac.openedDisplays, [7, 9], "已经在看这块就不重开")
    }

    /// 无显示器的 Mac：1 倍占位屏有同点数 2 倍模式就换过去，没有就建 2 倍虚拟屏；接着真显示器、不止一块屏、
    /// 已经是 2 倍时不动。
    func test_headless_placeholder_becomes_hidpi() {
        typealias Display = RemoteHeadlessDisplay
        typealias Mode = RemoteHeadlessDisplay.Mode
        let oneX = Mode(width: 1920, height: 1080, pixelWidth: 1920, pixelHeight: 1080)
        let twoX = Mode(width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160)
        let modes = [Mode(width: 1440, height: 900, pixelWidth: 2880, pixelHeight: 1800), oneX,
                     Mode(width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160, usable: false), twoX]
        func plan(vendor: UInt32 = Display.placeholderVendor, model: UInt32 = Display.placeholderModel,
                  builtin: Bool = false, online: Int = 1, current: Mode = oneX, available: [Mode]) -> Display.Plan {
            Display.plan(vendor: vendor, model: model, builtin: builtin, onlineDisplays: online, current: current,
                         available: available)
        }
        XCTAssertEqual(plan(available: [oneX]), .createVirtual, "真实的占位屏（unkn/virt）只有 1 倍：建虚拟屏")
        XCTAssertEqual(plan(available: modes), .switchMode(3), "带 2 倍模式就直接换")
        XCTAssertEqual(plan(vendor: Display.rememberedVendor, model: 0x1234, available: modes), .switchMode(3))
        XCTAssertEqual(plan(vendor: Display.rememberedVendor, model: 0x1234, available: [oneX]), .none)
        XCTAssertEqual(plan(current: twoX, available: modes), .none, "已经是 2 倍")
        XCTAssertEqual(plan(vendor: 0x10AC, available: [oneX]), .none, "真显示器")
        XCTAssertEqual(plan(online: 2, available: [oneX]), .none, "不止一块屏")
        XCTAssertEqual(plan(builtin: true, available: [oneX]), .none, "内建屏")
    }

    func test_old_mac_without_display_list_and_single_display_get_no_menu_data() async throws {
        let rig = try await makeRig()
        defer { rig.client.disconnect() }
        let session = RemoteDesktopSession(client: rig.client, maxWidth: 1920, maxHeight: 1080)
        defer { session.stop() }
        await session.start()
        XCTAssertNil(session.info?.displays, "只有一块（或老 Mac）时不报")
        let main = RemoteDesktopDisplaySummary(id: 1, name: "内建视网膜显示器", width: 1512, height: 982, isMain: true)
        XCTAssertEqual(RemoteDesktopContent.displayTitle(main), "内建视网膜显示器（主显示器，1512×982）")
    }

        private func shape(_ seed: UInt8, hot: Double) -> RemoteDesktopCursorImage {
        let png = image(width: 8 + Int(seed), height: 16, noise: false, type: .png)
        return RemoteDesktopCursorImage(png: png, width: 8 + Double(seed) / 2, height: 8, hotX: hot, hotY: hot)
    }

    func test_cursor_shape_is_sent_only_when_asked_and_only_when_it_changes() async throws {
        let rig = try await makeRig()
        defer { rig.client.disconnect() }
        let arrow = shape(0, hot: 1), beam = shape(4, hot: 3)
        rig.mac.cursorShape = arrow
        let phone = RemoteDesktopSession(client: rig.client, maxWidth: 1920, maxHeight: 1080)
        await phone.start()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(phone.cursorImage, "手机不要形状，Mac 就不发")
        XCTAssertEqual(rig.mac.cursorImageReads, 0)
        phone.stop()

        let mac = RemoteDesktopSession(client: rig.client, maxWidth: 1920, maxHeight: 1080, cursorImages: true)
        defer { mac.stop() }
        await mac.start()
        let first = await waitUntil { mac.cursorImage == arrow }
        XCTAssertTrue(first, "开流就发一次当前形状")
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(rig.mac.cursorImageReads, 1, "形状没变就不再取图、不再发")
        rig.mac.cursorShape = beam
        let changed = await waitUntil { mac.cursorImage == beam }
        XCTAssertTrue(changed)
        XCTAssertEqual(rig.mac.cursorImageReads, 2)
    }

    func test_cursor_image_becomes_a_local_cursor_with_its_size_and_hotspot() throws {
        let image = shape(4, hot: 3)
        let cursor = try XCTUnwrap(RemoteDesktopCanvasNSView.cursor(from: image))
        XCTAssertEqual(cursor.image.size, NSSize(width: 10, height: 8), "按点算，不按像素")
        XCTAssertEqual(cursor.hotSpot, NSPoint(x: 3, y: 3))
        XCTAssertNil(RemoteDesktopCanvasNSView.cursor(from: RemoteDesktopCursorImage(png: Data([1, 2]), width: 8, height: 8,
                                                                                     hotX: 0, hotY: 0)))
    }

    func test_system_cursor_sampler_produces_a_decodable_image() throws {
        guard let signature = RemoteSystemCursor.signature(), let image = RemoteSystemCursor.image() else {
            throw XCTSkip("这个进程拿不到系统光标")
        }
        XCTAssertEqual(signature, RemoteSystemCursor.signature(), "光标没变，指纹稳定")
        XCTAssertGreaterThan(image.width, 0)
        XCTAssertNotNil(NSImage(data: image.png))
        XCTAssertTrue(image.png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }

        // MARK: - 本机剪贴板

    private func image(width: Int, height: Int, noise: Bool, type: UTType) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        if noise {
            var generator = SystemRandomNumberGenerator()
            let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
            for i in 0..<(context.bytesPerRow * height) { pixels[i] = UInt8.random(in: 0...255, using: &generator) }
        } else {
            context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    func test_png_and_jpeg_pass_through_and_tiff_is_reencoded() async throws {
        let png = image(width: 40, height: 30, noise: false, type: .png)
        let pastedPNG = try await RemoteDesktopMacPasteSource.image(data: png)
        XCTAssertEqual(pastedPNG, .png(png), "截图原样发，字保持锐利")
        let jpeg = image(width: 40, height: 30, noise: false, type: .jpeg)
        let pastedJPEG = try await RemoteDesktopMacPasteSource.image(data: jpeg)
        XCTAssertEqual(pastedJPEG, .jpeg(jpeg))
        let tiff = image(width: 40, height: 30, noise: false, type: .tiff)
        guard case .png(let reencoded) = try await RemoteDesktopMacPasteSource.image(data: tiff) else {
            return XCTFail("TIFF 应转成 PNG（不少 app 读不了剪贴板里的 TIFF 以外格式时也认 PNG）")
        }
        XCTAssertTrue(reencoded.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }

    func test_oversized_image_is_compressed_under_the_limit() async throws {
        let png = image(width: 800, height: 800, noise: true, type: .png)
        let limit = 60_000
        XCTAssertGreaterThan(png.count, limit)
        guard case .jpeg(let jpeg) = try await RemoteDesktopMacPasteSource.image(data: png, limit: limit) else {
            return XCTFail("太大的图应转 JPEG")
        }
        XCTAssertLessThanOrEqual(jpeg.count, limit)
    }

    func test_reading_the_pasteboard_prefers_images_skips_files_and_returns_nil_when_empty() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let empty = try await RemoteDesktopMacPasteSource.read(board)
        XCTAssertNil(empty)

        board.clearContents()
        board.setString("拷贝的字", forType: .string)
        let text = try await RemoteDesktopMacPasteSource.read(board)
        XCTAssertEqual(text, .text("拷贝的字"))

        let png = image(width: 8, height: 8, noise: false, type: .png)
        board.clearContents()
        board.setData(png, forType: .png)
        let pasted = try await RemoteDesktopMacPasteSource.read(board)
        XCTAssertEqual(pasted, .png(png))

        board.clearContents()
        board.writeObjects([URL(fileURLWithPath: "/tmp/a.txt") as NSURL])
        let file = try await RemoteDesktopMacPasteSource.read(board)
        XCTAssertNil(file, "拷贝的是文件：⌘V 照常发过去，不接管")
    }

    func test_text_copied_on_the_remote_mac_lands_in_the_local_pasteboard() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let note = RemoteDesktopMacPasteSource.receive(.text("远端拷贝"), into: board)
        XCTAssertEqual(board.string(forType: .string), "远端拷贝")
        XCTAssertFalse(note.isEmpty)
        let previous = board.changeCount
        RemoteDesktopMacPasteSource.receive(.tooLarge(bytes: 5_000_000), into: board)
        XCTAssertEqual(board.changeCount, previous, "太大没传过来时不动本机剪贴板")
    }

    // MARK: - 窗口里的屏幕标签 + 画布（对着真实服务端）

    private struct Rig {
        let server: RemoteHostServer
        let mac: FakeDesktopMac
        let client: RemoteMacClient
    }

    private func makeRig() async throws -> Rig {
        let mac = FakeDesktopMac()
        let server = RemoteHostServer(registry: TerminalSessionRegistry(),
                                      identity: RemoteIdentityStore(role: .controllers, storage: RemoteMemoryStorage()),
                                      localName: "远程 Mac", localID: UUID(), advertises: false,
                                      localFeatures: RemoteConstants.localFeatures, desktopEnvironment: mac.environment())
        server.start()
        addTeardownBlock { @MainActor in server.stop() }
        let ready = await waitUntil { server.port != nil }
        XCTAssertTrue(ready)
        let identity = RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage())
        try server.trust(RemotePeer(id: RemoteLocalDevice.id(), name: "这台 Mac",
                                    publicKey: try identity.localIdentity().publicKey.rawRepresentation, pairedAt: Date(),
                                    platform: RemoteDevicePlatform.mac.rawValue))
        let port = try XCTUnwrap(NWEndpoint.Port(rawValue: try XCTUnwrap(server.port)))
        let client = RemoteMacClient(macName: "远程 Mac", endpoint: .hostPort(host: "127.0.0.1", port: port),
                                     identity: identity)
        await client.connect()
        XCTAssertEqual(client.state, .connected)
        return Rig(server: server, mac: mac, client: client)
    }

    func test_screen_window_connects_then_streams_and_stops_the_stream_on_close() async throws {
        let rig = try await makeRig()
        defer { rig.client.disconnect() }
        rig.client.disconnect()
        _ = await waitUntil { rig.client.state != .connected }
        let model = RemoteDesktopWindowModel(
            client: rig.client, session: RemoteDesktopSession(client: rig.client, maxWidth: 1920, maxHeight: 1080))
        await model.start()
        XCTAssertEqual(rig.client.state, .connected, "开窗口时没连着就先连")
        XCTAssertEqual(model.session.state, .streaming)
        await model.start()
        XCTAssertEqual(rig.mac.sources.count, 1, "已经在放就不重开")
        model.close()
        XCTAssertEqual(model.session.state, .idle, "关窗口停掉画面")
        XCTAssertEqual(rig.client.state, .connected, "连接由目录按窗口计数决定，窗口自己不断")
        await model.startStreamIfConnected()
        XCTAssertEqual(model.session.state, .idle, "关掉之后连接状态再变也不自己重开")
    }

    func test_shared_connection_is_dropped_only_when_the_last_window_lets_go() async throws {
        let rig = try await makeRig()
        rig.client.disconnect()
        let suite = "RemoteMacDesktopTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let identity = RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage())
        try rig.server.trust(RemotePeer(id: RemoteLocalDevice.id(), name: "这台 Mac",
                                        publicKey: try identity.localIdentity().publicKey.rawRepresentation,
                                        pairedAt: Date()))
        let directory = RemoteMacDirectory(identity: identity, defaults: defaults, adoptsRelayAsDefault: false)
        let port = try XCTUnwrap(NWEndpoint.Port(rawValue: try XCTUnwrap(rig.server.port)))
        let mac = RemoteMacDirectory.Mac(id: "mini", deviceID: nil, name: "远程 Mac", publicKey: nil, source: .debug,
                                         endpoint: .hostPort(host: "127.0.0.1", port: port))
        let terminals = directory.acquireClient(for: mac)
        let screen = directory.acquireClient(for: mac)
        XCTAssertTrue(terminals === screen, "终端窗口与屏幕窗口共用一条连接")
        await screen.connect()
        XCTAssertEqual(screen.state, .connected)
        directory.releaseClient(macID: mac.id)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(terminals.state, .connected, "关掉一扇窗口，另一扇照常连着")
        directory.releaseClient(macID: mac.id)
        let dropped = await waitUntil { terminals.state != .connected }
        XCTAssertTrue(dropped, "最后一扇窗口关掉才断开")
        directory.releaseClient(macID: mac.id)
    }

    func test_canvas_sends_absolute_clicks_keys_and_releases_held_keys_on_focus_loss() async throws {
        let rig = try await makeRig()
        defer { rig.client.disconnect() }
        let session = RemoteDesktopSession(client: rig.client, maxWidth: 1920, maxHeight: 1080)
        defer { session.stop() }
        await session.start()
        XCTAssertEqual(session.state, .streaming)
        let info = try XCTUnwrap(session.info)
        XCTAssertTrue(info.canControl)

        let canvas = RemoteDesktopCanvasNSView(session: session)
        defer { canvas.teardown() }
        // 窗口与那台 Mac 的屏幕同比例：整块正好铺满，没有黑边。
        let size = CGSize(width: info.displayWidth / 2, height: info.displayHeight / 2)
        // 放进屏幕可见区里：画布第一次拿到尺寸会把窗口对上那台的比例，比例已经对上就不动。
        let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: visible.minX + 10, y: visible.minY + 10), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = canvas
        canvas.update(displaySize: CGSize(width: info.displayWidth, height: info.displayHeight))
        window.layoutIfNeeded()
        canvas.layoutSubtreeIfNeeded()
        XCTAssertTrue(window.makeFirstResponder(canvas))

        // 窗口坐标原点在左下：画布左上 1/4 处。
        let point = CGPoint(x: size.width / 4, y: size.height * 3 / 4)
        func mouse(_ type: NSEvent.EventType, clicks: Int = 1) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: clicks,
                               pressure: 1)!
        }
        func key(_ type: NSEvent.EventType, _ code: UInt16, _ flags: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0,
                             windowNumber: window.windowNumber, context: nil, characters: "c",
                             charactersIgnoringModifiers: "c", isARepeat: false, keyCode: code)!
        }
        canvas.mouseDown(with: mouse(.leftMouseDown, clicks: 2))
        canvas.mouseUp(with: mouse(.leftMouseUp, clicks: 2))
        XCTAssertTrue(canvas.performKeyEquivalent(with: key(.keyDown, 0x08, [.command])), "⌘C 不进本机菜单")
        canvas.keyUp(with: key(.keyUp, 0x08, [.command]))
        canvas.keyDown(with: key(.keyDown, 0x00, []))
        _ = canvas.resignFirstResponder()

        let expected: [RemoteDesktopInput] = [
            .button(.left, down: true, clickCount: 2, x: 0.25, y: 0.25, modifiers: []),
            .button(.left, down: false, clickCount: 2, x: 0.25, y: 0.25, modifiers: []),
            .key(code: 0x08, down: true, modifiers: [.command]),
            .key(code: 0x08, down: false, modifiers: [.command]),
            .key(code: 0x00, down: true, modifiers: []),
            .key(code: 0x00, down: false, modifiers: []),
        ]
        let arrived = await waitUntil { rig.mac.injector.all.count >= expected.count }
        XCTAssertTrue(arrived, "\(rig.mac.injector.all)")
        XCTAssertEqual(rig.mac.injector.all, expected, "失焦时补抬起还按着的 A 键")
    }
}
