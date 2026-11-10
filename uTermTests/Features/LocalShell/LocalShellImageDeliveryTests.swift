import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import uTerm

/// 本机 shell 贴图：图片进剪贴板，再替用户按一下 Ctrl+V。起一个真 shell，走内嵌 XPC 服务。
/// 全程不碰系统剪贴板。
@MainActor
final class LocalShellImageDeliveryTests: XCTestCase {

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var images: [TerminalImage] = []
        func add(_ image: TerminalImage) {
            lock.lock()
            images.append(image)
            lock.unlock()
        }
        var all: [TerminalImage] {
            lock.lock()
            defer { lock.unlock() }
            return images
        }
    }

    private let png = TerminalImage(format: .png, data: Data([0x89, 0x50, 0x4E, 0x47]))

    func testRefusesBeforeConnectingWithoutTouchingPasteboard() async {
        let client = LocalShellAgentClient()
        defer { client.invalidate() }
        let recorder = Recorder()
        let backend = LocalShellBackend(client: client, columns: 80, rows: 24,
                                        writeImageToPasteboard: { recorder.add($0) })
        do {
            _ = try await backend.deliverImage(png)
            XCTFail("没连上不该成功")
        } catch TerminalImageError.notConnected {
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertTrue(recorder.all.isEmpty)
    }

    func testPutsImageOnPasteboardThenSendsControlV() async throws {
        let client = LocalShellAgentClient()
        defer { client.invalidate() }
        let recorder = Recorder()
        let backend = LocalShellBackend(client: client, columns: 80, rows: 24,
                                        writeImageToPasteboard: { recorder.add($0) })
        try await backend.connect()
        var output = ""
        let pump = Task { @MainActor in
            for await case .bytes(let chunk) in backend.outputItems { output += String(decoding: chunk, as: UTF8.self) }
        }
        defer { pump.cancel() }

        func waitFor(_ needle: String) async -> Bool {
            let deadline = Date().addingTimeInterval(15)
            while !output.contains(needle) {
                if Date() > deadline { return false }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return true
        }

        // 原始模式下 Ctrl+V 原样交给程序；cat -v 把它显示成 ^V，换行后才刷出来。
        await backend.write(Data("stty raw -echo; echo READY_$((40+2)); cat -v\n".utf8))
        let ready = await waitFor("READY_42")
        XCTAssertTrue(ready, String(output.suffix(300)))
        try await Task.sleep(for: .milliseconds(200))

        let delivery = try await backend.deliverImage(png)
        await backend.write(Data("\n".utf8))

        XCTAssertEqual(delivery, .clipboard)
        XCTAssertEqual(recorder.all, [png])
        let controlV = await waitFor("^V")
        XCTAssertTrue(controlV, "程序没收到 Ctrl+V：\(output.suffix(300))")

        XCTAssertTrue(backend.programsCanReadMacClipboard)
        await backend.close()
        do {
            _ = try await backend.deliverImage(png)
            XCTFail("关闭后不该成功")
        } catch TerminalImageError.notConnected {
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertEqual(recorder.all.count, 1)
    }

    // MARK: - 写剪贴板

    private func withPasteboard(_ body: (NSPasteboard) throws -> Void) rethrows {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("uterm-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        try body(pasteboard)
    }

    func testPNGIsWrittenAsIs() {
        withPasteboard { pasteboard in
            RemotePasteboard.write(png, to: pasteboard)
            XCTAssertEqual(pasteboard.data(forType: .png), png.data)
        }
    }

    /// Claude Code 等按 PNG 读剪贴板，只放 JPEG 它们读不到。
    func testJPEGAlsoGetsAPNGCopy() throws {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 3,
            hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let jpeg = try XCTUnwrap(rep.representation(using: .jpeg, properties: [:]))

        try withPasteboard { pasteboard in
            RemotePasteboard.write(TerminalImage(format: .jpeg, data: jpeg), to: pasteboard)
            XCTAssertEqual(pasteboard.data(forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier)), jpeg)
            let copy = try XCTUnwrap(pasteboard.data(forType: .png))
            XCTAssertNotNil(NSBitmapImageRep(data: copy))
        }
    }

    func testWritingReplacesWhatWasThere() {
        withPasteboard { pasteboard in
            RemotePasteboard.write(text: "旧文字", to: pasteboard)
            XCTAssertEqual(pasteboard.string(forType: .string), "旧文字")
            RemotePasteboard.write(png, to: pasteboard)
            XCTAssertNil(pasteboard.string(forType: .string), "留着文字的话贴图路径会把它当文字贴")
        }
    }
}
