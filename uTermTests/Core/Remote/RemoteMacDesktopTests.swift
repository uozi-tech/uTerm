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

    private func makeModel(_ client: RemoteMacClient) -> RemoteMacWindowModel {
        RemoteMacWindowModel(client: client, startTerminal: { _ in }, makeDesktop: { client in
            let pane = RemoteDesktopPane(session: RemoteDesktopSession(client: client, maxWidth: 1920, maxHeight: 1080))
            Task { await pane.session.start() }
            return pane
        })
    }

    func test_screen_tab_is_one_per_window_survives_terminal_follow_and_stops_when_closed() async throws {
        let rig = try await makeRig()
        defer { rig.client.disconnect() }
        let model = makeModel(rig.client)
        model.takeOver()
        model.openDesktop()
        let desktop = try XCTUnwrap(model.desktop)
        let streaming = await waitUntil { desktop.session.state == .streaming }
        XCTAssertTrue(streaming, "\(desktop.session.state)")
        XCTAssertTrue(model.panes.isEmpty, "终端列表里不含屏幕标签")
        XCTAssertEqual(model.tabCount, 1)

        model.openDesktop()
        XCTAssertEqual(model.tabCount, 1, "再点一次只带到前台")
        XCTAssertTrue(model.desktop === desktop)

        model.follow([])
        XCTAssertNotNil(model.desktop, "那台 Mac 的终端列表变化不影响屏幕标签")

        XCTAssertTrue(model.close(desktop.id))
        XCTAssertEqual(desktop.session.state, .idle, "关标签停掉画面")
        XCTAssertNil(model.desktop)
        model.disposeAll()
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
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = canvas
        canvas.update(displaySize: CGSize(width: info.displayWidth, height: info.displayHeight), scaleMode: .fit)
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
