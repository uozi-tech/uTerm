import AppKit
import Carbon.HIToolbox
import XCTest
@testable import uTerm

/// 只有图片的剪贴板在 Mac 终端里怎么走。
@MainActor
final class TerminalImagePasteTests: XCTestCase {

    /// 记录写入的后端，贴图结果可控。
    private actor ImageBackend: TerminalImageReceiving {
        nonisolated let outputItems: AsyncStream<TerminalOutputItem>
        nonisolated let exitStream: AsyncStream<Void>
        nonisolated let programsCanReadMacClipboard: Bool
        private let outputContinuation: AsyncStream<TerminalOutputItem>.Continuation
        private let exitContinuation: AsyncStream<Void>.Continuation
        private(set) var written: [Data] = []
        private(set) var delivered: [uTerm.TerminalImage] = []
        private let failure: TerminalImageError?

        init(canReadClipboard: Bool = false, failure: TerminalImageError? = nil) {
            programsCanReadMacClipboard = canReadClipboard
            self.failure = failure
            (outputItems, outputContinuation) = AsyncStream<TerminalOutputItem>.makeStream()
            (exitStream, exitContinuation) = AsyncStream<Void>.makeStream()
        }

        func connect() async throws {}
        func write(_ data: Data) async { written.append(data) }
        func resize(cols: UInt16, rows: UInt16) async {}
        func close() async {
            outputContinuation.finish()
            exitContinuation.finish()
        }
        func deliverImage(_ image: uTerm.TerminalImage) async throws -> TerminalImageDelivery {
            if let failure { throw failure }
            delivered.append(image)
            return .file(path: "/tmp/shot.png")
        }
    }

    private let png = Data([0x89, 0x50, 0x4E, 0x47])
    private var pasteboard: NSPasteboard!
    private var session: TerminalSession!
    private var view: GhosttySurfaceView!
    private var attentions: [TerminalAttention] = []

    override func setUp() async throws {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("uterm-test-\(UUID().uuidString)"))
        session = TerminalSession()
        view = session.ghostty.view
        view.pasteboard = pasteboard
        attentions = []
        session.attentionSink = { [unowned self] in self.attentions.append($0) }
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
    }

    private func putImage() {
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
    }

    private func connect(_ backend: ImageBackend) async {
        await session.connect(using: backend)
    }

    private func reportAgent() {
        session.feedOutput(text: "\u{1b}]7501;state=idle:app=claude-code\u{1b}\\")
    }

    private func enableBracketedPaste() {
        session.feedOutput(text: "\u{1b}[?2004h")
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("等待超时")
    }

    // MARK: 从剪贴板取图

    func testReadsImageOnlyPasteboard() {
        putImage()
        XCTAssertEqual(uTerm.TerminalImage.fromPasteboard(pasteboard), uTerm.TerminalImage(format: .png, data: png))
    }

    /// Finder 复制文件、Word 复制内容都同时带文字和图片：用户要的是文字。
    func testTextWinsOverImage() {
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        pasteboard.setString("hello", forType: .string)
        XCTAssertNil(uTerm.TerminalImage.fromPasteboard(pasteboard))
    }

    /// 系统截图放进剪贴板的常是 TIFF，远端程序读不了，要转 PNG。
    func testConvertsTIFFToPNG() throws {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                 isPlanar: false, colorSpaceName: .deviceRGB,
                                                 bytesPerRow: 0, bitsPerPixel: 0))
        pasteboard.clearContents()
        pasteboard.setData(try XCTUnwrap(rep.tiffRepresentation), forType: .tiff)
        let image = try XCTUnwrap(uTerm.TerminalImage.fromPasteboard(pasteboard))
        XCTAssertEqual(image.format, .png)
        XCTAssertEqual(image.data.prefix(4), png)
    }

    // MARK: ⌘V

    func testCommandVOverSSHUploadsAndPastesPath() async throws {
        let backend = ImageBackend()
        await connect(backend)
        enableBracketedPaste()
        putImage()

        view.paste(self)

        let expected = Data("\u{1b}[200~/tmp/shot.png \u{1b}[201~".utf8)
        try await waitUntil { await backend.written.contains(expected) }
        let delivered = await backend.delivered
        XCTAssertEqual(delivered.count, 1)
    }

    func testPathIsSentPlainWithoutBracketedPaste() async throws {
        let backend = ImageBackend()
        await connect(backend)
        putImage()

        view.paste(self)

        try await waitUntil { await backend.written.contains(Data("/tmp/shot.png ".utf8)) }
    }

    /// 本机 shell 贴图靠替用户按 Ctrl+V，没有 Agent 时那是 zsh 的转义输入。
    func testCommandVInLocalShellWithoutAgentIsNotTaken() async {
        await connect(ImageBackend(canReadClipboard: true))
        XCTAssertFalse(session.pasteImage(uTerm.TerminalImage(format: .png, data: png)))
    }

    func testCommandVInLocalShellWithAgentIsTaken() async {
        await connect(ImageBackend(canReadClipboard: true))
        reportAgent()
        XCTAssertTrue(session.pasteImage(uTerm.TerminalImage(format: .png, data: png)))
    }

    func testBackendWithoutImageSupportFallsBackToNormalPaste() async {
        await session.connect(using: MockBackend())
        XCTAssertFalse(session.pasteImage(uTerm.TerminalImage(format: .png, data: png)))
    }

    func testDeliveryFailureIsShown() async throws {
        await connect(ImageBackend(failure: .notConnected))
        XCTAssertTrue(session.pasteImage(uTerm.TerminalImage(format: .png, data: png)))
        try await waitUntil { await MainActor.run { !self.attentions.isEmpty } }
        XCTAssertEqual(attentions.first?.title, "图片发送失败")
    }

    // MARK: ⌃V

    private func controlV() throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control],
                                       timestamp: 0, windowNumber: 0, context: nil,
                                       characters: "\u{16}", charactersIgnoringModifiers: "v",
                                       isARepeat: false, keyCode: UInt16(kVK_ANSI_V)))
    }

    private func hostInWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(view)
        window.makeFirstResponder(view)
        return window
    }

    func testControlVOverSSHWithAgentUploads() async throws {
        let backend = ImageBackend()
        await connect(backend)
        reportAgent()
        putImage()
        let window = hostInWindow()
        defer { window.close() }

        XCTAssertTrue(view.performKeyEquivalent(with: try controlV()))

        try await waitUntil { await !backend.delivered.isEmpty }
    }

    /// vim、zsh 里 Ctrl+V 有自己的含义。
    func testControlVWithoutAgentGoesToProgram() async {
        await connect(ImageBackend())
        XCTAssertFalse(session.handleControlVImage(uTerm.TerminalImage(format: .png, data: png)))
    }

    /// 本机程序能自己读剪贴板，按键原样发过去。
    func testControlVInLocalShellGoesToProgram() async {
        await connect(ImageBackend(canReadClipboard: true))
        reportAgent()
        XCTAssertFalse(session.handleControlVImage(uTerm.TerminalImage(format: .png, data: png)))
    }

    func testControlVWithTextOnClipboardGoesToProgram() async throws {
        await connect(ImageBackend())
        reportAgent()
        pasteboard.clearContents()
        pasteboard.setString("hello", forType: .string)
        let window = hostInWindow()
        defer { window.close() }

        let handled = view.performKeyEquivalent(with: try controlV())

        XCTAssertFalse(handled)
    }
}
